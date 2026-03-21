#!/usr/bin/env bash
# =============================================================================
# Chaos Mesh 제거 스크립트
#
# 사용법:
#   ./uninstall-chaos-mesh.sh            # 일반 제거
#   ./uninstall-chaos-mesh.sh --force    # Terminating 강제 정리 포함
# =============================================================================
set -euo pipefail

CHAOS_NS="chaos-testing"
FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

echo "============================================="
echo " Chaos Mesh 제거"
echo "============================================="

# 1. 활성 실험 중단
echo "[1/5] 실험 중단..."
for kind in podchaos networkchaos stresschaos iochaos httpchaos dnschaos; do
  kubectl delete "$kind" --all -n "$CHAOS_NS" --ignore-not-found 2>/dev/null || true
done

# 2. RBAC
echo "[2/5] RBAC 제거..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/manifests/chaos/chaos-rbac.yaml" ]]; then
  kubectl delete -f "${SCRIPT_DIR}/manifests/chaos/chaos-rbac.yaml" --ignore-not-found 2>/dev/null || true
else
  kubectl delete clusterrolebinding chaos-mesh-target-access --ignore-not-found 2>/dev/null || true
  kubectl delete clusterrole chaos-mesh-target-access --ignore-not-found 2>/dev/null || true
fi

# 3. Helm release
echo "[3/5] Helm release..."
if helm status chaos-mesh -n "$CHAOS_NS" &>/dev/null 2>&1; then
  helm uninstall chaos-mesh -n "$CHAOS_NS" --wait --timeout 2m 2>/dev/null || {
    echo "  helm uninstall 실패. secret 강제 삭제..."
    kubectl delete secret -n "$CHAOS_NS" -l owner=helm --ignore-not-found 2>/dev/null || true
  }
else
  kubectl delete secret -n "$CHAOS_NS" -l owner=helm --ignore-not-found 2>/dev/null || true
  echo "  Helm release 없음"
fi

# 4. CRD (namespace보다 먼저! Terminating 방지)
echo "[4/5] CRD 제거..."
CRDS=$(kubectl get crd -o name 2>/dev/null | grep chaos-mesh || true)
if [[ -n "$CRDS" ]]; then
  echo "$CRDS" | xargs kubectl delete --ignore-not-found 2>/dev/null || true
fi

# 5. namespace
echo "[5/5] namespace..."
if kubectl get ns "$CHAOS_NS" &>/dev/null 2>&1; then
  kubectl delete namespace "$CHAOS_NS" --timeout=60s 2>/dev/null || {
    echo "  삭제 타임아웃. finalizer 제거..."
    kubectl get ns "$CHAOS_NS" -o json \
      | jq '.spec.finalizers = []' \
      | kubectl replace --raw "/api/v1/namespaces/${CHAOS_NS}/finalize" -f - 2>/dev/null || true
    sleep 5
  }

  # 아직 남아있으면
  if kubectl get ns "$CHAOS_NS" &>/dev/null 2>&1 && $FORCE; then
    echo "  --force: finalizer 강제 제거..."
    kubectl get ns "$CHAOS_NS" -o json \
      | jq '.spec.finalizers = []' \
      | kubectl replace --raw "/api/v1/namespaces/${CHAOS_NS}/finalize" -f - 2>/dev/null || true
    sleep 5
  fi
fi

# 검증
echo ""
echo "============================================="
echo " 검증"
echo "============================================="
kubectl get crd 2>/dev/null | grep chaos-mesh || echo "  CRD: 없음 OK"
kubectl get ns "$CHAOS_NS" 2>/dev/null || echo "  namespace: 없음 OK"
echo ""
echo " 재설치: ./install-chaos-mesh.sh"
echo "============================================="