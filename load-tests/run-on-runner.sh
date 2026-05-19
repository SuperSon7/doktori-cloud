#!/bin/bash
# 러너에서 실행되는 스크립트 (SSM Run Command로 호출)
# 사용법: /home/ubuntu/5-team-service-cloud/load-tests/run-on-runner.sh <scenario> [--pull] [--prom URL]
set -e
export HOME="${HOME:-/root}"

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
RESULT_DIR="${RESULT_DIR:-/tmp/k6-results}"
RUN_NAME="${RUN_NAME:-$(basename "${SCENARIO}" .js)}"
RAW_EXPORT="${K6_RAW_EXPORT:-false}"
K6_EXTRA_ARGS="${K6_EXTRA_ARGS:-}"
K6_SUMMARY_TREND_STATS="${K6_SUMMARY_TREND_STATS:-avg,min,med,max,p(90),p(95),p(99)}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "${RESULT_DIR}"
RESULT_FILE="${RESULT_DIR}/${RUN_NAME}_${TIMESTAMP}.log"
SUMMARY_FILE="${RESULT_DIR}/${RUN_NAME}_${TIMESTAMP}_summary.json"
RAW_FILE="${RESULT_DIR}/${RUN_NAME}_${TIMESTAMP}_raw.json"

K6_OUT_ARG=""
if [ -n "${K6_PROMETHEUS_RW_SERVER_URL:-}" ]; then
  export K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true
  K6_OUT_ARG="--out experimental-prometheus-rw"
elif [ "${RAW_EXPORT}" = "true" ]; then
  K6_OUT_ARG="--out json=${RAW_FILE}"
fi

echo "=== k6 run: ${SCENARIO} ==="
echo "BASE_URL: ${BASE_URL}"
echo "PROM: ${K6_PROMETHEUS_RW_SERVER_URL:-none}"
echo "Result: ${RESULT_FILE}"
echo "Summary: ${SUMMARY_FILE}"
if [ "${RAW_EXPORT}" = "true" ]; then
  echo "Raw: ${RAW_FILE}"
fi
echo ""

K6_CMD=(k6 run --summary-export "${SUMMARY_FILE}" --summary-trend-stats "${K6_SUMMARY_TREND_STATS}")
if [ -n "${K6_OUT_ARG}" ]; then
  K6_CMD+=(${=K6_OUT_ARG})
fi
if [ -n "${K6_EXTRA_ARGS}" ]; then
  K6_CMD+=(${=K6_EXTRA_ARGS})
fi
K6_CMD+=("${SCENARIO}")

"${K6_CMD[@]}" 2>&1 | tee "${RESULT_FILE}"

echo ""
echo "SUMMARY_FILE=${SUMMARY_FILE}"
echo "RESULT_FILE=${RESULT_FILE}"
if [ "${RAW_EXPORT}" = "true" ] && [ -f "${RAW_FILE}" ]; then
  echo "RAW_FILE=${RAW_FILE}"
fi
