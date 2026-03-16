#!/usr/bin/env bash
# =============================================================================
# 07. ArgoCD + Security 설치 스크립트
# NetworkPolicy + ArgoCD (Helm)
#
# 사용법: master 노드에서 실행
#   chmod +x install-argocd.sh
#   ./install-argocd.sh
#
# ※ etcd 암호화, kubelet 보안은 수동 작업 필요 (스크립트 하단 안내)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "============================================="
echo " 07. ArgoCD + Security 설치"
echo "============================================="

# -----------------------------------------------------------------------------
# 0. Helm 확인
# -----------------------------------------------------------------------------
if ! command -v helm &>/dev/null; then
  echo "[ERROR] Helm이 설치되어 있지 않습니다."
  exit 1
fi

# -----------------------------------------------------------------------------
# 1. NetworkPolicy
# -----------------------------------------------------------------------------
echo ""
echo "[1/3] NetworkPolicy 적용..."
echo "  default-deny + NGF→api + NGF→chat + monitoring→apps"

kubectl apply -f "${SCRIPT_DIR}/manifests/security/netpol-all.yaml"

echo "  → 서비스 동작 확인 필요:"
echo "    curl http://<NLB_DNS>/api/health"
echo "    curl http://<NLB_DNS>/api/chat/health"

# -----------------------------------------------------------------------------
# 2. ArgoCD (Helm)
# -----------------------------------------------------------------------------
echo ""
echo "[2/3] ArgoCD 설치..."

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

if helm status argocd -n argocd &>/dev/null; then
  echo "  → 이미 설치됨. 업그레이드 확인..."
  helm upgrade argocd argo/argo-cd \
    --namespace argocd \
    --version "${ARGOCD_CHART_VERSION}" \
    -f "${SCRIPT_DIR}/helm/argocd-values.yaml"
else
  helm install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --version "${ARGOCD_CHART_VERSION}" \
    -f "${SCRIPT_DIR}/helm/argocd-values.yaml"
fi

echo "  → ArgoCD Pod 대기 중..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=120s 2>/dev/null || true

# -----------------------------------------------------------------------------
# 3. 초기 비밀번호 + 접근 안내
# -----------------------------------------------------------------------------
echo ""
echo "[3/3] ArgoCD 접근 정보..."

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "아직 생성 안 됨")

echo ""
echo "============================================="
echo " ArgoCD 설치 완료"
echo "============================================="
echo ""
echo "  Username: admin"
echo "  Password: ${ARGOCD_PASSWORD}"
echo ""
echo "  접근 방법 (port-forward):"
echo "    kubectl port-forward svc/argocd-server -n argocd 8443:443 --address=0.0.0.0"
echo "    → https://localhost:8443"
echo ""
echo "  접근 방법 (NodePort):"
echo "    kubectl patch svc argocd-server -n argocd -p '{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"name\":\"https\",\"port\":443,\"nodePort\":${ARGOCD_NODEPORT},\"targetPort\":8080}]}}'"
echo "    → https://<Worker-IP>:${ARGOCD_NODEPORT}"
echo ""
echo "============================================="
echo " 수동 작업 필요 (master 노드에서):"
echo "============================================="
echo ""
echo " [A] Git 저장소 연결:"
echo "   kubectl apply -f - <<EOF"
echo "   apiVersion: v1"
echo "   kind: Secret"
echo "   metadata:"
echo "     name: private-repo-creds"
echo "     namespace: argocd"
echo "     labels:"
echo "       argocd.argoproj.io/secret-type: repository"
echo "   type: Opaque"
echo "   stringData:"
echo "     type: git"
echo "     url: <GIT_REPO_URL>"
echo "     username: <GIT_USERNAME>"
echo "     password: <GIT_PAT>"
echo "   EOF"
echo ""
echo " [B] etcd 암호화 (Secret 보호):"
echo "   ENCRYPTION_KEY=\$(head -c 32 /dev/urandom | base64)"
echo "   # → 가이드: K8s_provisioning/07_argocd.md § Phase 1.2"
echo ""
echo " [C] kubelet 보안 (모든 노드):"
echo "   # /var/lib/kubelet/config.yaml 수정:"
echo "   #   authentication.anonymous.enabled: false"
echo "   #   readOnlyPort: 0"
echo "   sudo systemctl restart kubelet"
echo ""
echo " [D] ArgoCD 비밀번호 변경:"
echo "   argocd login localhost:8443 --username admin --password '${ARGOCD_PASSWORD}' --insecure"
echo "   argocd account update-password"
echo "============================================="