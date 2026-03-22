#!/usr/bin/env bash
# =============================================================================
# Chaos Mesh 설치 스크립트
# k8s 클러스터에 Chaos Mesh를 설치하고 FI 실험용 namespace를 구성한다.
#
# 사용법: master 노드에서 실행
#   chmod +x install-chaos-mesh.sh
#   ./install-chaos-mesh.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.env"

CHAOS_MESH_VERSION="2.7.2"

echo "============================================="
echo " Chaos Mesh 설치"
echo "============================================="

# -----------------------------------------------------------------------------
# 0. Helm 확인
# -----------------------------------------------------------------------------
if ! command -v helm &>/dev/null; then
  echo "[ERROR] Helm이 설치되어 있지 않습니다."
  exit 1
fi

# -----------------------------------------------------------------------------
# 1. chaos-testing namespace
# -----------------------------------------------------------------------------
echo ""
echo "[1/3] chaos-testing 네임스페이스..."

kubectl create namespace chaos-testing 2>/dev/null || echo "  → 이미 존재"
kubectl label namespace chaos-testing kubernetes.io/metadata.name=chaos-testing --overwrite

# -----------------------------------------------------------------------------
# 2. Chaos Mesh 설치 (Helm)
# -----------------------------------------------------------------------------
echo ""
echo "[2/3] Chaos Mesh v${CHAOS_MESH_VERSION} 설치..."

helm repo add chaos-mesh https://charts.chaos-mesh.org 2>/dev/null || true
helm repo update chaos-mesh

if helm status chaos-mesh -n chaos-testing &>/dev/null; then
  echo "  → 이미 설치됨. 업그레이드 확인..."
  helm upgrade chaos-mesh chaos-mesh/chaos-mesh \
    --namespace chaos-testing \
    --version "${CHAOS_MESH_VERSION}" \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
    --set dashboard.securityMode=false \
    --set controllerManager.resources.requests.cpu=100m \
    --set controllerManager.resources.requests.memory=128Mi \
    --set controllerManager.resources.limits.memory=512Mi \
    --set chaosDaemon.resources.requests.cpu=100m \
    --set chaosDaemon.resources.requests.memory=128Mi \
    --set chaosDaemon.resources.limits.memory=256Mi
else
  helm install chaos-mesh chaos-mesh/chaos-mesh \
    --namespace chaos-testing \
    --version "${CHAOS_MESH_VERSION}" \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
    --set dashboard.securityMode=false \
    --set controllerManager.resources.requests.cpu=100m \
    --set controllerManager.resources.requests.memory=128Mi \
    --set controllerManager.resources.limits.memory=512Mi \
    --set chaosDaemon.resources.requests.cpu=100m \
    --set chaosDaemon.resources.requests.memory=128Mi \
    --set chaosDaemon.resources.limits.memory=256Mi
fi

# -----------------------------------------------------------------------------
# 3. RBAC — chaos-testing에서 prod namespace 접근 허용
# -----------------------------------------------------------------------------
echo ""
echo "[3/3] RBAC 설정..."

kubectl apply -f "${SCRIPT_DIR}/manifests/chaos/chaos-rbac.yaml"

# -----------------------------------------------------------------------------
# 검증
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo " 설치 완료 — 검증"
echo "============================================="

echo ""
echo "--- chaos-testing namespace pods ---"
kubectl get pods -n chaos-testing

echo ""
echo "--- Chaos Mesh CRDs ---"
kubectl get crd | grep chaos-mesh || echo "  CRD 아직 생성 중..."

echo ""
echo "============================================="
echo " 다음 단계:"
echo "   1. Pod 전부 Running 확인: kubectl get pods -n chaos-testing -w"
echo "   2. Dashboard 접속: kubectl port-forward -n chaos-testing svc/chaos-dashboard 2333:2333"
echo "   3. 실험 적용: kubectl apply -f manifests/chaos/fi-1-api-pod-kill.yaml"
echo "   4. 실험 확인: kubectl get podchaos,networkchaos,stresschaos -n chaos-testing"
echo "   5. 실험 중단: kubectl delete -f manifests/chaos/<파일>.yaml"
echo "============================================="