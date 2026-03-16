#!/usr/bin/env bash
# =============================================================================
# 06. Observability 설치 스크립트
# metrics-server + kube-state-metrics (Helm) + HPA + Alloy DaemonSet
#
# 사용법: master 노드에서 실행
#   chmod +x install-observability.sh
#   ./install-observability.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.env"

echo "============================================="
echo " 06. Observability 설치"
echo "============================================="

# -----------------------------------------------------------------------------
# 0. Helm 확인
# -----------------------------------------------------------------------------
if ! command -v helm &>/dev/null; then
  echo "[ERROR] Helm이 설치되어 있지 않습니다."
  echo "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  exit 1
fi

# -----------------------------------------------------------------------------
# 1. metrics-server (Helm)
# -----------------------------------------------------------------------------
echo ""
echo "[1/5] metrics-server 설치..."

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo update metrics-server

if helm status metrics-server -n kube-system &>/dev/null; then
  echo "  → 이미 설치됨. 업그레이드 확인..."
  helm upgrade metrics-server metrics-server/metrics-server \
    --namespace kube-system \
    --version "${METRICS_SERVER_VERSION}" \
    --set args[0]=--kubelet-insecure-tls \
    --set args[1]=--kubelet-preferred-address-types=InternalIP \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
    --set resources.limits.memory=256Mi
else
  helm install metrics-server metrics-server/metrics-server \
    --namespace kube-system \
    --version "${METRICS_SERVER_VERSION}" \
    --set args[0]=--kubelet-insecure-tls \
    --set args[1]=--kubelet-preferred-address-types=InternalIP \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
    --set resources.limits.memory=256Mi
fi

echo "  → metrics-server 설치 완료. 메트릭 수집까지 1~2분 소요."

# -----------------------------------------------------------------------------
# 2. monitoring 네임스페이스
# -----------------------------------------------------------------------------
echo ""
echo "[2/5] monitoring 네임스페이스..."

kubectl create namespace monitoring 2>/dev/null || echo "  → 이미 존재"
kubectl label namespace monitoring kubernetes.io/metadata.name=monitoring --overwrite

# -----------------------------------------------------------------------------
# 3. kube-state-metrics (Helm)
# -----------------------------------------------------------------------------
echo ""
echo "[3/5] kube-state-metrics 설치..."

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community

if helm status kube-state-metrics -n monitoring &>/dev/null; then
  echo "  → 이미 설치됨. 업그레이드 확인..."
  helm upgrade kube-state-metrics prometheus-community/kube-state-metrics \
    --namespace monitoring \
    --version "${KUBE_STATE_METRICS_VERSION}" \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
    --set resources.limits.memory=256Mi
else
  helm install kube-state-metrics prometheus-community/kube-state-metrics \
    --namespace monitoring \
    --version "${KUBE_STATE_METRICS_VERSION}" \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
    --set resources.limits.memory=256Mi
fi

# -----------------------------------------------------------------------------
# 4. Alloy DaemonSet
# -----------------------------------------------------------------------------
echo ""
echo "[4/5] Alloy DaemonSet 배포..."

kubectl apply -f "${SCRIPT_DIR}/manifests/monitoring/alloy-rbac.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/monitoring/alloy-configmap.yaml"

# DaemonSet에 config.env 버전 주입
sed "s|__ALLOY_VERSION__|${ALLOY_VERSION}|g" \
  "${SCRIPT_DIR}/manifests/monitoring/alloy-daemonset.yaml" | kubectl apply -f -

# -----------------------------------------------------------------------------
# 5. HPA
# -----------------------------------------------------------------------------
echo ""
echo "[5/5] HPA 적용..."

kubectl apply -f "${SCRIPT_DIR}/manifests/hpa/chat-hpa.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/hpa/api-hpa.yaml"

# -----------------------------------------------------------------------------
# 검증
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo " 설치 완료 — 검증"
echo "============================================="

echo ""
echo "--- Helm releases ---"
helm list -A

echo ""
echo "--- monitoring namespace pods ---"
kubectl get pods -n monitoring

echo ""
echo "--- HPA ---"
kubectl get hpa -n "${NAMESPACE}"

echo ""
echo "--- metrics-server (1~2분 후 동작) ---"
kubectl top nodes 2>/dev/null || echo "  아직 메트릭 수집 중... 1~2분 후 'kubectl top nodes' 재시도"

echo ""
echo "============================================="
echo " 다음 단계:"
echo "   1. kubectl top pods -n ${NAMESPACE}  → 메트릭 확인"
echo "   2. HPA TARGETS에 CPU % 표시 확인"
echo "   3. Alloy UI: kubectl port-forward -n monitoring ds/alloy 12345:12345"
echo "   4. Grafana에서 up{env=\"prod-k8s\"} 쿼리로 수신 확인"
echo "============================================="