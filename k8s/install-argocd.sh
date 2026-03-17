#!/usr/bin/env bash
# =============================================================================
# 07. ArgoCD + Security 설치 스크립트
# NetworkPolicy + ArgoCD (Helm)
#
# 사용법: master 노드에서 실행
#   chmod +x install-argocd.sh
#   ./install-argocd.sh
#
# 설치 후 초기 설정 (Git 연결, etcd 암호화, kubelet 보안, 비밀번호 변경):
#   ./setup-argocd.sh
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
echo " 다음 단계: 초기 설정"
echo "============================================="
echo ""
echo "  아래 스크립트로 Git 연결 + 보안 설정을 자동화할 수 있습니다:"
echo ""
echo "    ./setup-argocd.sh"
echo ""
echo "  자동화 항목:"
echo "    [A] Git 저장소 연결 + ArgoCD Application 배포"
echo "    [B] etcd 암호화 (Secret 보호)"
echo "    [C] kubelet 보안 (anonymous auth 비활성화)"
echo "    [D] ArgoCD admin 비밀번호 변경"
echo ""
echo "  옵션:"
echo "    --skip-etcd     etcd 암호화 건너뜀"
echo "    --skip-kubelet  kubelet 보안 건너뜀"
echo "============================================="