#!/usr/bin/env bash
# =============================================================================
# FI-8: Graceful Shutdown 검증
#
# 사용법:
#   1. 별도 터미널에서 k6 부하 실행:
#      k6 run --env BASE_URL=http://<endpoint>/api load-tests/k6/scenarios/load.js
#
#   2. 이 스크립트 실행:
#      ./fi-8-graceful-shutdown.sh
#
#   3. k6 결과에서 errors rate = 0 확인
#
# 가설: pre-stop hook (15s sleep) 동안 in-flight 요청이 완료되어 유실 0건
# 성공 기준: Pod 삭제 중 5xx = 0건, 요청 유실 0건
#
# FI-1(Pod kill)과의 차이:
#   - FI-1: gracePeriod=0 → 즉시 SIGKILL (최악 상황)
#   - FI-8: gracePeriod=30 → pre-stop hook 실행 후 SIGTERM (정상 종료)
# =============================================================================
set -euo pipefail

NAMESPACE="prod"

echo "============================================="
echo " FI-8: Graceful Shutdown 검증"
echo "============================================="

# API Pod 목록
API_PODS=$(kubectl get pods -n "$NAMESPACE" -l component=api -o jsonpath='{.items[*].metadata.name}')
POD_COUNT=$(echo "$API_PODS" | wc -w | tr -d ' ')

if [[ "$POD_COUNT" -lt 2 ]]; then
  echo "[ERROR] API Pod가 ${POD_COUNT}개뿐입니다. 최소 2개 이상이어야 안전합니다."
  exit 1
fi

# 첫 번째 Pod 선택
TARGET_POD=$(echo "$API_PODS" | awk '{print $1}')

echo ""
echo "  대상 Pod: ${TARGET_POD}"
echo "  전체 API Pod: ${POD_COUNT}개"
echo ""

read -p "k6 부하가 실행 중입니까? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
  echo "k6를 먼저 실행한 후 다시 시도하세요."
  exit 1
fi

echo ""
echo "[1/3] 삭제 전 상태..."
kubectl get pods -n "$NAMESPACE" -l component=api -o wide
echo ""

echo "[2/3] Pod 삭제 (grace-period=30s, pre-stop hook 실행됨)..."
echo "  $(date '+%H:%M:%S') 삭제 시작"
kubectl delete pod "$TARGET_POD" -n "$NAMESPACE" --grace-period=30

echo "  $(date '+%H:%M:%S') 삭제 완료"
echo ""

echo "[3/3] 새 Pod 대기..."
kubectl wait --for=condition=Ready pod -l component=api -n "$NAMESPACE" --timeout=120s

echo ""
echo "============================================="
echo " 검증 완료"
echo "============================================="
echo ""
kubectl get pods -n "$NAMESPACE" -l component=api -o wide
echo ""
echo "✅ k6 결과에서 errors rate를 확인하세요."
echo "   - errors = 0% → Graceful Shutdown 정상 동작"
echo "   - errors > 0% → pre-stop hook 시간 또는 readiness probe 조정 필요"