#!/usr/bin/env bash
# =============================================================================
# Chaos Mesh 설치 스크립트
#
# 사용법: master 노드에서 실행
#   ./install-chaos-mesh.sh            # 기본 설치
#   ./install-chaos-mesh.sh --force    # 기존 설치 제거 후 재설치
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.env"

CHAOS_MESH_VERSION="${CHAOS_MESH_VERSION:-2.7.1}"
CHAOS_NS="chaos-testing"
INSTALL_TIMEOUT="5m"
FORCE=false

[[ "${1:-}" == "--force" ]] && FORCE=true

echo "============================================="
echo " Chaos Mesh v${CHAOS_MESH_VERSION} 설치"
echo "============================================="

# 0. 사전 확인
if ! command -v helm &>/dev/null; then echo "[ERROR] Helm 필요"; exit 1; fi
if ! kubectl cluster-info &>/dev/null; then echo "[ERROR] kubectl 연결 불가"; exit 1; fi

# --force 시 기존 설치 제거
if $FORCE; then
  echo ""
  echo "[0/4] --force: 기존 설치 제거..."
  "${SCRIPT_DIR}/uninstall-chaos-mesh.sh" --force || true
  sleep 10
fi

# 이미 설치 확인
if helm status chaos-mesh -n "$CHAOS_NS" &>/dev/null 2>&1; then
  echo "Chaos Mesh 이미 설치됨. 재설치: $0 --force"
  kubectl get pods -n "$CHAOS_NS"
  exit 0
fi

# 1. namespace
echo ""
echo "[1/4] namespace..."
if kubectl get ns "$CHAOS_NS" &>/dev/null 2>&1; then
  NS_PHASE=$(kubectl get ns "$CHAOS_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "$NS_PHASE" == "Terminating" ]]; then
    echo "  Terminating 상태 강제 정리..."
    kubectl get ns "$CHAOS_NS" -o json | jq '.spec.finalizers = []' \
      | kubectl replace --raw "/api/v1/namespaces/${CHAOS_NS}/finalize" -f -
    sleep 5
    kubectl create namespace "$CHAOS_NS"
  fi
else
  kubectl create namespace "$CHAOS_NS"
fi
kubectl label namespace "$CHAOS_NS" kubernetes.io/metadata.name="$CHAOS_NS" --overwrite

# 2. Helm 설치
echo ""
echo "[2/4] Helm install (--wait --timeout ${INSTALL_TIMEOUT})..."
helm repo add chaos-mesh https://charts.chaos-mesh.org 2>/dev/null || true
helm repo update chaos-mesh

helm install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace "$CHAOS_NS" \
  --version "${CHAOS_MESH_VERSION}" \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --set dashboard.securityMode=false \
  --set controllerManager.replicaCount=1 \
  --set controllerManager.resources.requests.cpu=100m \
  --set controllerManager.resources.requests.memory=128Mi \
  --set controllerManager.resources.limits.memory=512Mi \
  --set chaosDaemon.resources.requests.cpu=100m \
  --set chaosDaemon.resources.requests.memory=128Mi \
  --set chaosDaemon.resources.limits.memory=256Mi \
  --wait --timeout "$INSTALL_TIMEOUT"

if [[ $? -ne 0 ]]; then
  echo ""
  echo "[ERROR] 설치 실패. Pod/이벤트 확인:"
  kubectl get pods -n "$CHAOS_NS" -o wide
  kubectl get events -n "$CHAOS_NS" --sort-by='.lastTimestamp' | tail -15
  echo ""
  echo "정리 후 재시도: ./uninstall-chaos-mesh.sh --force && ./install-chaos-mesh.sh"
  exit 1
fi

# 3. RBAC
echo ""
echo "[3/4] RBAC..."
kubectl apply -f "${SCRIPT_DIR}/manifests/chaos/chaos-rbac.yaml"

# 4. 검증
echo ""
echo "[4/4] 검증..."
kubectl get pods -n "$CHAOS_NS" -o wide
echo ""

CRD_COUNT=$(kubectl get crd 2>/dev/null | grep -c chaos-mesh || true)
echo "CRD: ${CRD_COUNT}개"

FAIL=0
for f in "${SCRIPT_DIR}"/manifests/chaos/fi-*.yaml; do
  [[ ! -f "$f" ]] && continue
  if kubectl apply -f "$f" --dry-run=server &>/dev/null 2>&1; then
    echo "  OK $(basename "$f")"
  else
    echo "  FAIL $(basename "$f")"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "============================================="
echo " 설치 완료 (dry-run 실패: ${FAIL}건)"
echo ""
echo " 실험: cd manifests/chaos && ./run-experiment.sh apply fi-1"
echo " 제거: ./uninstall-chaos-mesh.sh"
echo "============================================="