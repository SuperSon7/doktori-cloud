#!/usr/bin/env bash
# =============================================================================
# Chaos Mesh 제거 스크립트
#
# 사용법: master 노드에서 실행
#   chmod +x uninstall-chaos-mesh.sh
#   ./uninstall-chaos-mesh.sh
# =============================================================================
set -euo pipefail

echo "============================================="
echo " Chaos Mesh 제거"
echo "============================================="

# -----------------------------------------------------------------------------
# 1. 활성 실험 전부 중단
# -----------------------------------------------------------------------------
echo ""
echo "[1/4] 활성 실험 중단..."

for kind in podchaos networkchaos stresschaos iochaos httpchaos dnschaos; do
  kubectl delete "$kind" --all -n chaos-testing --ignore-not-found 2>/dev/null || true
done
echo "  → 실험 정리 완료"

# -----------------------------------------------------------------------------
# 2. RBAC 제거
# -----------------------------------------------------------------------------
echo ""
echo "[2/4] RBAC 제거..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RBAC_FILE="${SCRIPT_DIR}/manifests/chaos/chaos-rbac.yaml"

if [[ -f "$RBAC_FILE" ]]; then
  kubectl delete -f "$RBAC_FILE" --ignore-not-found
else
  kubectl delete clusterrolebinding chaos-mesh-target-access --ignore-not-found
  kubectl delete clusterrole chaos-mesh-target-access --ignore-not-found
fi
echo "  → RBAC 제거 완료"

# -----------------------------------------------------------------------------
# 3. Helm release 제거
# -----------------------------------------------------------------------------
echo ""
echo "[3/4] Chaos Mesh Helm release 제거..."

if helm status chaos-mesh -n chaos-testing &>/dev/null; then
  helm uninstall chaos-mesh -n chaos-testing
  echo "  → Helm release 제거 완료"
else
  echo "  → Helm release 없음 (이미 제거됨)"
fi

# -----------------------------------------------------------------------------
# 4. CRD 및 namespace 제거
# -----------------------------------------------------------------------------
echo ""
echo "[4/4] CRD + namespace 정리..."

kubectl get crd -o name | grep chaos-mesh | xargs -r kubectl delete --ignore-not-found
echo "  → CRD 제거 완료"

kubectl delete namespace chaos-testing --ignore-not-found
echo "  → namespace 제거 완료"

# -----------------------------------------------------------------------------
# 검증
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo " 제거 완료 — 검증"
echo "============================================="

echo ""
echo "--- Chaos Mesh CRD (없어야 정상) ---"
kubectl get crd | grep chaos-mesh || echo "  없음 ✅"

echo ""
echo "--- chaos-testing namespace (없어야 정상) ---"
kubectl get namespace chaos-testing 2>/dev/null || echo "  없음 ✅"

echo ""
echo "--- prod Pod 상태 ---"
kubectl get pods -n prod -o wide

echo ""
echo "============================================="
echo " Chaos Mesh가 완전히 제거되었습니다."
echo "============================================="