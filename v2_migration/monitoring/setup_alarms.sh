#!/usr/bin/env bash
# =============================================================================
# setup_alarms.sh — CloudWatch 알람 자동 생성
# alert_rules.json을 읽어 CloudWatch 알람을 자동으로 생성한다.
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_FILE="${SCRIPT_DIR}/alert_rules.json"
REGION="${AWS_REGION:-ap-northeast-2}"
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-}"

if [ ! -f "$RULES_FILE" ]; then
    echo "alert_rules.json 파일을 찾을 수 없습니다: ${RULES_FILE}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "jq가 필요합니다: brew install jq"
    exit 1
fi

ALARM_COUNT=$(jq '.alarms | length' "$RULES_FILE")

echo "=========================================="
echo " CloudWatch 알람 생성 (${ALARM_COUNT}개)"
echo "=========================================="
echo ""

for i in $(seq 0 $((ALARM_COUNT - 1))); do
    NAME=$(jq -r ".alarms[$i].name" "$RULES_FILE")
    DESC=$(jq -r ".alarms[$i].description" "$RULES_FILE")
    METRIC=$(jq -r ".alarms[$i].metric" "$RULES_FILE")
    NAMESPACE=$(jq -r ".alarms[$i].namespace" "$RULES_FILE")
    DIM_NAME=$(jq -r ".alarms[$i].dimension_name" "$RULES_FILE")
    DIM_VALUE=$(jq -r ".alarms[$i].dimension_value" "$RULES_FILE")
    STAT=$(jq -r ".alarms[$i].statistic" "$RULES_FILE")
    PERIOD=$(jq -r ".alarms[$i].period" "$RULES_FILE")
    EVAL=$(jq -r ".alarms[$i].evaluation_periods" "$RULES_FILE")
    THRESHOLD=$(jq -r ".alarms[$i].threshold" "$RULES_FILE")
    COMP=$(jq -r ".alarms[$i].comparison_operator" "$RULES_FILE")
    MISSING=$(jq -r ".alarms[$i].treat_missing_data" "$RULES_FILE")

    CMD="aws cloudwatch put-metric-alarm \
        --alarm-name '${NAME}' \
        --alarm-description '${DESC}' \
        --metric-name '${METRIC}' \
        --namespace '${NAMESPACE}' \
        --dimensions Name='${DIM_NAME}',Value='${DIM_VALUE}' \
        --statistic '${STAT}' \
        --period ${PERIOD} \
        --evaluation-periods ${EVAL} \
        --threshold ${THRESHOLD} \
        --comparison-operator '${COMP}' \
        --treat-missing-data '${MISSING}' \
        --region '${REGION}'"

    if [ -n "$SNS_TOPIC_ARN" ]; then
        CMD="${CMD} --alarm-actions '${SNS_TOPIC_ARN}'"
    fi

    eval "$CMD" 2>/dev/null
    echo -e "  ${GREEN}[OK]${NC} ${NAME} (${METRIC} ${COMP} ${THRESHOLD})"
done

echo ""
echo -e "${GREEN}모든 알람 생성 완료${NC}"

if [ -z "$SNS_TOPIC_ARN" ]; then
    echo -e "${YELLOW}[INFO]${NC} SNS_TOPIC_ARN이 설정되지 않아 알람 액션이 없습니다."
    echo "  알림을 받으려면: SNS_TOPIC_ARN=arn:aws:sns:... ./setup_alarms.sh"
fi
