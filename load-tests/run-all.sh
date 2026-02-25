#!/bin/bash
#
# 전체 부하테스트 실행 스크립트
#
# 사용법:
#   export BASE_URL="https://your-api.com/api"
#   export JWT_TOKEN="your-token"
#   ./run-all.sh
#

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 결과 저장 디렉토리
RESULTS_DIR="results/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo -e "${GREEN}=========================================="
echo " Doktori 부하테스트 실행"
echo -e "==========================================${NC}"
echo ""
echo "BASE_URL: ${BASE_URL:-미설정}"
echo "JWT_TOKEN: ${JWT_TOKEN:+설정됨}${JWT_TOKEN:-미설정}"
echo "결과 저장: $RESULTS_DIR"
echo ""

# 환경변수 체크
if [ -z "$BASE_URL" ]; then
    echo -e "${RED}오류: BASE_URL 환경변수가 설정되지 않았습니다.${NC}"
    echo "export BASE_URL=\"https://your-api.com/api\""
    exit 1
fi

# 함수: 테스트 실행
run_test() {
    local name=$1
    local script=$2
    local output_file="$RESULTS_DIR/${name}.json"

    echo -e "${YELLOW}[$(date +%H:%M:%S)] $name 시작...${NC}"

    if k6 run --out json="$output_file" "$script" 2>&1 | tee "$RESULTS_DIR/${name}.log"; then
        echo -e "${GREEN}[$(date +%H:%M:%S)] $name 완료${NC}"
    else
        echo -e "${RED}[$(date +%H:%M:%S)] $name 실패${NC}"
    fi

    echo ""
    sleep 5  # 테스트 간 간격
}

# 1. Smoke 테스트
echo -e "${GREEN}=== 1. Smoke 테스트 (기능 검증) ===${NC}"
run_test "01_smoke" "k6/scenarios/smoke.js"

# 2. 비회원 흐름
echo -e "${GREEN}=== 2. 비회원 탐색 흐름 ===${NC}"
run_test "02_guest_flow" "k6/scenarios/guest-flow.js"

# 3. 로그인 사용자 흐름 (토큰 필요)
if [ -n "$JWT_TOKEN" ]; then
    echo -e "${GREEN}=== 3. 로그인 사용자 흐름 ===${NC}"
    run_test "03_user_flow" "k6/scenarios/user-flow.js"
else
    echo -e "${YELLOW}=== 3. 로그인 사용자 흐름 (건너뜀 - 토큰 없음) ===${NC}"
fi

# 4. 모임 검색 병목 테스트
echo -e "${GREEN}=== 4. 모임 검색 병목 테스트 ===${NC}"
run_test "04_meeting_search" "k6/scenarios/meeting-search.js"

# 5. N+1 문제 테스트 (토큰 필요)
if [ -n "$JWT_TOKEN" ]; then
    echo -e "${GREEN}=== 5. N+1 문제 테스트 ===${NC}"
    run_test "05_my_meetings_n1" "k6/scenarios/my-meetings-n1.js"

    echo -e "${GREEN}=== 6. 오늘의 모임 (DATE 인덱스) 테스트 ===${NC}"
    run_test "06_today_meetings" "k6/scenarios/today-meetings.js"
fi

# 7. 종합 Load 테스트
echo -e "${GREEN}=== 7. 종합 Load 테스트 ===${NC}"
run_test "07_load" "k6/scenarios/load.js"

# 8. Stress 테스트
echo -e "${GREEN}=== 8. Stress 테스트 ===${NC}"
run_test "08_stress" "k6/scenarios/stress.js"

# 9. Spike 테스트
echo -e "${GREEN}=== 9. Spike 테스트 ===${NC}"
run_test "09_spike" "k6/scenarios/spike.js"

echo -e "${GREEN}=========================================="
echo " 테스트 완료!"
echo -e "==========================================${NC}"
echo ""
echo "결과 파일: $RESULTS_DIR/"
ls -la "$RESULTS_DIR/"
echo ""
echo "요약 보기:"
echo "  cat $RESULTS_DIR/*.log | grep -E '(http_req_duration|http_req_failed|errors)'"
