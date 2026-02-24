#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${ROOT_DIR}/logs"
TS="$(date +%Y%m%d_%H%M%S)"

SCRIPT_PATH="${SCRIPT_PATH:-${ROOT_DIR}/script_scenario2_probe.js}"
BASE_URL="${BASE_URL:-https://doktori.kr}"
VUS="${VUS:-30}"
DURATION="${DURATION:-10m}"
ENV_NAME="${ENV_NAME:-local}"

SUMMARY_FILE="${LOG_DIR}/run_${VUS}vus_${DURATION}_summary_${TS}.json"
LOG_FILE="${LOG_DIR}/run_${VUS}vus_${DURATION}_${TS}.log"
REPORT_FILE="${LOG_DIR}/run_${VUS}vus_${DURATION}_report_${TS}.md"
REPORT_HTML_FILE="${LOG_DIR}/run_${VUS}vus_${DURATION}_report_${TS}.html"
RAW_FILE="${LOG_DIR}/run_${VUS}vus_${DURATION}_raw_${TS}.json"
REPORT_HTML_ABS="$(cd "$(dirname "${REPORT_HTML_FILE}")" && pwd)/$(basename "${REPORT_HTML_FILE}")"

mkdir -p "${LOG_DIR}"

echo "[INFO] k6 실행 시작"
echo "[INFO] script=${SCRIPT_PATH}"
echo "[INFO] base_url=${BASE_URL} vus=${VUS} duration=${DURATION}"
echo "[INFO] env_name=${ENV_NAME}"

BASE_URL="${BASE_URL}" VUS="${VUS}" DURATION="${DURATION}" \
  k6 run --summary-export "${SUMMARY_FILE}" --out "json=${RAW_FILE}" "${SCRIPT_PATH}" | tee "${LOG_FILE}"

echo "[INFO] 표 리포트 생성"
node "${ROOT_DIR}/generate_k6_table_report.mjs" \
  --summary "${SUMMARY_FILE}" \
  --log "${LOG_FILE}" \
  --raw "${RAW_FILE}" \
  --env-name "${ENV_NAME}" \
  --vus "${VUS}" \
  --duration "${DURATION}" \
  --base-url "${BASE_URL}" \
  --script "${SCRIPT_PATH}" \
  --out "${REPORT_FILE}" \
  --html-out "${REPORT_HTML_FILE}" >/dev/null

echo "[INFO] logs 정리 (HTML 제외 삭제)"
find "${LOG_DIR}" -maxdepth 1 -type f ! -name "*.html" -delete

echo ""
echo "[DONE] HTML 리포트"
echo "${REPORT_HTML_ABS}"
