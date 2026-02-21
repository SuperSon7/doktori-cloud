#!/bin/bash
# ============================================================
# 마이그레이션 부하 테스트 실행 스크립트
#
# 사용법:
#   ./run-migration-test.sh <시나리오> [옵션]
#
# 시나리오:
#   db-cutover       DB 컷오버 중 읽기/쓰기 가용성 (10분)
#   dns-switch       DNS 전환 중 전체 가용성 (30분)
#   connpool         커넥션 풀 복원력 (10분)
#   websocket        WebSocket 전환 안정성 (15분)
#   full-journey     전체 사용자 여정 (15분)
#   all              전체 순차 실행
#
# 옵션:
#   --json           JSON 출력 (Grafana 시각화용)
#   --html           HTML 리포트 생성
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/../../../result/migration"
mkdir -p "$RESULT_DIR"

# ── 환경변수 확인 ──
if [ -z "${BASE_URL:-}" ]; then
    echo "❌ BASE_URL이 설정되지 않았습니다."
    echo "   export BASE_URL=https://doktori.kr/api"
    exit 1
fi

if [ -z "${JWT_TOKEN:-}" ]; then
    echo "⚠️  JWT_TOKEN이 설정되지 않았습니다. 인증 필요 API는 실패합니다."
    echo "   export JWT_TOKEN=<토큰>"
fi

SCENARIO="${1:-help}"
EXTRA_ARGS=""
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# 옵션 파싱
shift || true
for arg in "$@"; do
    case $arg in
        --json)
            EXTRA_ARGS="$EXTRA_ARGS --out json=${RESULT_DIR}/${SCENARIO}-${TIMESTAMP}.json"
            ;;
        --html)
            EXTRA_ARGS="$EXTRA_ARGS --out html=${RESULT_DIR}/${SCENARIO}-${TIMESTAMP}.html"
            ;;
    esac
done

run_scenario() {
    local name=$1
    local file=$2
    local desc=$3

    echo ""
    echo "========================================"
    echo " $desc"
    echo " $(date '+%Y-%m-%d %H:%M:%S')"
    echo " 대상: $BASE_URL"
    echo "========================================"
    echo ""

    k6 run \
        --env BASE_URL="${BASE_URL}" \
        --env JWT_TOKEN="${JWT_TOKEN:-}" \
        --env REFRESH_TOKEN="${REFRESH_TOKEN:-}" \
        --env WS_URL="${WS_URL:-wss://doktori.kr/ws}" \
        --env CHAT_BASE_URL="${CHAT_BASE_URL:-${BASE_URL}}" \
        --env TEST_MEETING_ID="${TEST_MEETING_ID:-1}" \
        $EXTRA_ARGS \
        "${SCRIPT_DIR}/${file}" \
        2>&1 | tee "${RESULT_DIR}/${name}-${TIMESTAMP}.log"

    echo ""
    echo "결과 저장: ${RESULT_DIR}/${name}-${TIMESTAMP}.log"
}

case $SCENARIO in
    db-cutover)
        run_scenario "db-cutover" "db-cutover-traffic.js" \
            "DB 컷오버 부하 테스트 (10분)"
        ;;
    dns-switch)
        run_scenario "dns-switch" "dns-switch-availability.js" \
            "DNS 전환 가용성 테스트 (30분)"
        ;;
    connpool)
        run_scenario "connpool" "connection-pool-resilience.js" \
            "커넥션 풀 복원력 테스트 (10분)"
        ;;
    websocket)
        run_scenario "websocket" "websocket-migration.js" \
            "WebSocket 마이그레이션 테스트 (15분)"
        ;;
    full-journey)
        run_scenario "full-journey" "full-user-journey.js" \
            "전체 사용자 여정 테스트 (15분)"
        ;;
    all)
        echo "=== 전체 마이그레이션 테스트 순차 실행 ==="
        echo ""
        echo "순서: db-cutover → connpool → full-journey → websocket → dns-switch"
        echo "총 예상 시간: ~80분"
        echo ""
        read -p "시작하시겠습니까? (y/N): " CONFIRM
        [ "$CONFIRM" != "y" ] && exit 0

        run_scenario "db-cutover" "db-cutover-traffic.js" "DB 컷오버 (10분)"
        sleep 5
        run_scenario "connpool" "connection-pool-resilience.js" "커넥션 풀 (10분)"
        sleep 5
        run_scenario "full-journey" "full-user-journey.js" "사용자 여정 (15분)"
        sleep 5
        run_scenario "websocket" "websocket-migration.js" "WebSocket (15분)"
        sleep 5
        run_scenario "dns-switch" "dns-switch-availability.js" "DNS 전환 (30분)"

        echo ""
        echo "=== 전체 테스트 완료 ==="
        echo "결과: ${RESULT_DIR}/"
        ;;
    help|*)
        echo "사용법: $0 <시나리오> [--json] [--html]"
        echo ""
        echo "시나리오:"
        echo "  db-cutover     DB 컷오버 중 읽기/쓰기 가용성 (10분)"
        echo "  dns-switch     DNS 전환 중 전체 가용성 (30분)"
        echo "  connpool       커넥션 풀 복원력 (10분)"
        echo "  websocket      WebSocket 전환 안정성 (15분)"
        echo "  full-journey   전체 사용자 여정 (15분)"
        echo "  all            전체 순차 실행 (~80분)"
        echo ""
        echo "환경변수:"
        echo "  BASE_URL       API 기본 URL (필수)"
        echo "  JWT_TOKEN      인증 토큰 (인증 API용)"
        echo "  WS_URL         WebSocket URL (websocket 시나리오)"
        echo "  TEST_MEETING_ID 테스트 모임 ID"
        ;;
esac
