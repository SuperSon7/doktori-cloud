#!/bin/bash
# ============================================================
# 마이그레이션 이벤트 Grafana Annotation 마커
#
# 용도: 마이그레이션 각 단계 시작/종료 시 Grafana에 annotation을 생성하여
#       대시보드에서 이벤트 시점을 시각적으로 확인할 수 있게 한다.
#
# 사용법:
#   ./annotate.sh <이벤트명> [설명]
#
# 예시:
#   ./annotate.sh "DB Cutover Start" "Master read_only 설정"
#   ./annotate.sh "DB Cutover End" "RDS 승격 완료"
#   ./annotate.sh "Nginx Switch" "upstream을 VPC로 변경"
#   ./annotate.sh "DNS Switch" "Route 53 A레코드 변경"
#   ./annotate.sh "Rollback" "문제 발생으로 롤백"
#
# 포트폴리오 핵심:
#   Grafana 대시보드에서 마이그레이션 이벤트와 메트릭 변화를
#   시간축으로 정확히 대조할 수 있는 시각적 증거
# ============================================================

set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-http://13.125.29.187:3000}"
GRAFANA_API_KEY="${GRAFANA_API_KEY:-}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASS="${GRAFANA_PASS:-admin}"

EVENT="${1:-Migration Event}"
DESCRIPTION="${2:-}"
TIMESTAMP=$(date +%s)000  # milliseconds

# 색상 매핑
case "$EVENT" in
    *Start*|*start*)    COLOR="blue" ;;
    *End*|*end*)        COLOR="green" ;;
    *Rollback*|*fail*)  COLOR="red" ;;
    *Switch*|*switch*)  COLOR="orange" ;;
    *)                  COLOR="purple" ;;
esac

# Annotation 생성 (API Key 방식)
if [ -n "$GRAFANA_API_KEY" ]; then
    AUTH_HEADER="Authorization: Bearer ${GRAFANA_API_KEY}"
else
    AUTH_HEADER="Authorization: Basic $(echo -n "${GRAFANA_USER}:${GRAFANA_PASS}" | base64)"
fi

RESPONSE=$(curl -s -X POST "${GRAFANA_URL}/api/annotations" \
    -H "Content-Type: application/json" \
    -H "$AUTH_HEADER" \
    -d "{
        \"time\": ${TIMESTAMP},
        \"tags\": [\"migration\", \"$(echo $EVENT | tr ' ' '-' | tr '[:upper:]' '[:lower:]')\"],
        \"text\": \"<b>${EVENT}</b><br>${DESCRIPTION}<br>$(date '+%Y-%m-%d %H:%M:%S')\"
    }" 2>/dev/null)

if echo "$RESPONSE" | grep -q '"id"'; then
    ANNO_ID=$(echo "$RESPONSE" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
    echo "[$(date '+%H:%M:%S')] Annotation #${ANNO_ID}: ${EVENT}"
    echo "  ${DESCRIPTION}"
    echo "  Dashboard: ${GRAFANA_URL}/d/migration-monitor"
else
    echo "[$(date '+%H:%M:%S')] Annotation 생성 실패"
    echo "  응답: ${RESPONSE}"
    echo ""
    echo "  확인사항:"
    echo "  1. GRAFANA_URL=${GRAFANA_URL} 접속 가능한지"
    echo "  2. GRAFANA_API_KEY 또는 GRAFANA_USER/PASS 설정"
    echo "  3. Grafana API가 활성화되어 있는지"
fi
