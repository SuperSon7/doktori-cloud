#!/bin/bash
# 러너에서 실행되는 스크립트 (SSM Run Command로 호출)
# 사용법: /home/ubuntu/5-team-service-cloud/load-tests/run-on-runner.sh <scenario> [--pull] [--prom URL]
set -e

SCENARIO="${1:?시나리오를 지정하세요}"
REPO_DIR="/home/ubuntu/5-team-service-cloud"
WORK_DIR="${REPO_DIR}/load-tests"

git config --global --add safe.directory "$REPO_DIR"
cd "$WORK_DIR"

# 옵션 파싱
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --pull) git pull --ff-only; shift ;;
    --prom) export K6_PROMETHEUS_RW_SERVER_URL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

export BASE_URL="${BASE_URL:-https://api.doktori.kr/api}"
export WS_URL="${WS_URL:-wss://api.doktori.kr/ws/chat}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_FILE="/tmp/k6-${TIMESTAMP}.log"

K6_ARGS=""
if [ -n "$K6_PROMETHEUS_RW_SERVER_URL" ]; then
  export K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true
  K6_ARGS="--out experimental-prometheus-rw"
fi

echo "=== k6 run: ${SCENARIO} ==="
echo "BASE_URL: ${BASE_URL}"
echo "PROM: ${K6_PROMETHEUS_RW_SERVER_URL:-none}"
echo "Result: ${RESULT_FILE}"
echo ""

k6 run $K6_ARGS "$SCENARIO" 2>&1 | tee "$RESULT_FILE"
