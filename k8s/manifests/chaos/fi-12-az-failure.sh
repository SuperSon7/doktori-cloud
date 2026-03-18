#!/usr/bin/env bash
# =============================================================================
# FI-12: AZ 단위 장애
#
# 한 AZ의 모든 워커 노드를 drain하여 AZ 장애를 시뮬레이션
#
# 사용법:
#   ./fi-12-az-failure.sh drain <az-suffix>    # 장애 주입 (예: ap-northeast-2a → "2a")
#   ./fi-12-az-failure.sh recover <az-suffix>   # 복구
#
# 가설: 멀티 AZ 배포 + topology spread로 한 AZ가 사라져도 서비스 지속
# 성공 기준: drain 후 2분 이내 다른 AZ에서 Pod Running, SLO-1/3 유지
# =============================================================================
set -euo pipefail

usage() {
  echo "사용법: $0 {drain|recover} <az-suffix>"
  echo "  예: $0 drain 2a       → ap-northeast-2a 노드 전부 drain"
  echo "  예: $0 recover 2a     → ap-northeast-2a 노드 uncordon"
  exit 1
}

[[ $# -lt 2 ]] && usage

ACTION="$1"
AZ_SUFFIX="$2"
TARGET_AZ="ap-northeast-${AZ_SUFFIX}"

echo "============================================="
echo " FI-12: AZ 단위 장애 — ${TARGET_AZ}"
echo "============================================="

# 해당 AZ의 노드 찾기
NODES=$(kubectl get nodes -o jsonpath="{range .items[*]}{.metadata.name}{'\t'}{.metadata.labels.topology\.kubernetes\.io/zone}{'\n'}{end}" | grep "$TARGET_AZ" | awk '{print $1}')

if [[ -z "$NODES" ]]; then
  # label이 없는 경우 노드 이름에서 AZ 추론
  echo "  topology label이 없습니다. 노드를 수동으로 선택하세요:"
  kubectl get nodes -o wide
  echo ""
  read -p "drain할 노드 이름 (쉼표 구분): " MANUAL_NODES
  NODES=$(echo "$MANUAL_NODES" | tr ',' '\n')
fi

NODE_COUNT=$(echo "$NODES" | wc -l | tr -d ' ')
echo ""
echo "  대상 AZ: ${TARGET_AZ}"
echo "  대상 노드 (${NODE_COUNT}개):"
echo "$NODES" | while read node; do echo "    - ${node}"; done
echo ""

case "$ACTION" in
  drain)
    echo "[1/3] 장애 전 Pod 분포..."
    kubectl get pods -n prod -o wide
    echo ""

    read -p "위 ${NODE_COUNT}개 노드를 drain합니까? (y/n): " confirm
    [[ "$confirm" != "y" ]] && echo "취소됨." && exit 0

    echo ""
    echo "[2/3] 노드 drain 시작..."
    echo "$NODES" | while read node; do
      echo "  draining ${node}..."
      kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=120s || true
    done

    echo ""
    echo "[3/3] drain 후 Pod 분포..."
    kubectl get pods -n prod -o wide
    echo ""
    echo "✅ AZ 장애 시뮬레이션 완료."
    echo "   SLO 대시보드를 확인하세요."
    echo "   복구: $0 recover ${AZ_SUFFIX}"
    ;;

  recover)
    echo "노드 uncordon..."
    echo "$NODES" | while read node; do
      echo "  uncordon ${node}..."
      kubectl uncordon "$node"
    done
    echo ""
    echo "✅ 복구 완료."
    kubectl get nodes
    ;;

  *)
    usage
    ;;
esac