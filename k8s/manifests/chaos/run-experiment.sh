#!/usr/bin/env bash
# =============================================================================
# FI 실험 실행/중단/상태 확인 헬퍼
#
# 사용법:
#   ./run-experiment.sh apply  fi-1    # FI-1 실험 시작
#   ./run-experiment.sh delete fi-1    # FI-1 실험 중단
#   ./run-experiment.sh status         # 모든 실험 상태 확인
#   ./run-experiment.sh stop-all       # 모든 실험 즉시 중단
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NS="chaos-testing"

usage() {
  echo "사용법: $0 {apply|delete|status|stop-all} [fi-번호]"
  echo ""
  echo "  apply  fi-1   → FI-1 실험 시작"
  echo "  delete fi-1   → FI-1 실험 중단"
  echo "  status        → 활성 실험 목록"
  echo "  stop-all      → 모든 실험 즉시 중단"
  exit 1
}

[[ $# -lt 1 ]] && usage

ACTION="$1"
FI_ID="${2:-}"

case "$ACTION" in
  apply)
    [[ -z "$FI_ID" ]] && usage
    FILE=$(ls "${SCRIPT_DIR}/${FI_ID}"*.yaml 2>/dev/null | head -1)
    if [[ -z "$FILE" ]]; then
      echo "[ERROR] ${FI_ID}에 해당하는 YAML 파일을 찾을 수 없습니다."
      ls "${SCRIPT_DIR}"/fi-*.yaml
      exit 1
    fi
    echo "▶ 실험 시작: ${FILE}"
    echo "  실험 전 Pod 상태:"
    kubectl get pods -n prod -o wide
    echo ""
    kubectl apply -f "$FILE"
    echo ""
    echo "✅ 실험 적용됨. 관측 시작하세요:"
    echo "  kubectl get pods -n prod -w"
    echo "  kubectl get hpa -n prod -w"
    echo "  Grafana 대시보드 확인"
    ;;
  delete)
    [[ -z "$FI_ID" ]] && usage
    FILE=$(ls "${SCRIPT_DIR}/${FI_ID}"*.yaml 2>/dev/null | head -1)
    if [[ -z "$FILE" ]]; then
      echo "[ERROR] ${FI_ID}에 해당하는 YAML 파일을 찾을 수 없습니다."
      exit 1
    fi
    echo "⏹ 실험 중단: ${FILE}"
    kubectl delete -f "$FILE" --ignore-not-found
    echo "✅ 실험 중단됨."
    ;;
  status)
    echo "=== 활성 Chaos 실험 ==="
    echo ""
    echo "--- PodChaos ---"
    kubectl get podchaos -n "$NS" 2>/dev/null || echo "  없음"
    echo ""
    echo "--- NetworkChaos ---"
    kubectl get networkchaos -n "$NS" 2>/dev/null || echo "  없음"
    echo ""
    echo "--- StressChaos ---"
    kubectl get stresschaos -n "$NS" 2>/dev/null || echo "  없음"
    echo ""
    echo "--- prod Pod 상태 ---"
    kubectl get pods -n prod -o wide
    echo ""
    echo "--- HPA ---"
    kubectl get hpa -n prod
    ;;
  stop-all)
    echo "⚠️  모든 실험 즉시 중단..."
    kubectl delete podchaos --all -n "$NS" --ignore-not-found
    kubectl delete networkchaos --all -n "$NS" --ignore-not-found
    kubectl delete stresschaos --all -n "$NS" --ignore-not-found
    echo "✅ 모든 실험 중단됨."
    echo ""
    kubectl get pods -n prod -o wide
    ;;
  *)
    usage
    ;;
esac