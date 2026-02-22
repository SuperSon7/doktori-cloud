#!/bin/bash
#
# 단일 시나리오 실행 스크립트
#
# 사용법:
#   export BASE_URL="https://your-api.com/api"
#   export JWT_TOKEN="your-token"
#   ./run-single.sh <시나리오>
#
# 예시:
#   ./run-single.sh smoke
#   ./run-single.sh guest-flow
#   ./run-single.sh meeting-search
#

set -e

# 사용 가능한 시나리오 목록
SCENARIOS=(
    "smoke"
    "load"
    "stress"
    "spike"
    "soak"
    "guest-flow"
    "user-flow"
    "meeting-search"
    "today-meetings"
    "my-meetings-n1"
    "join-meeting"
)

# 도움말
show_help() {
    echo "사용법: ./run-single.sh <시나리오>"
    echo ""
    echo "사용 가능한 시나리오:"
    for s in "${SCENARIOS[@]}"; do
        echo "  - $s"
    done
    echo ""
    echo "예시:"
    echo "  ./run-single.sh smoke"
    echo "  ./run-single.sh meeting-search"
}

# 인자 체크
if [ -z "$1" ]; then
    show_help
    exit 1
fi

SCENARIO=$1
SCRIPT_FILE="k6/scenarios/${SCENARIO}.js"

# 파일 존재 확인
if [ ! -f "$SCRIPT_FILE" ]; then
    echo "오류: '$SCRIPT_FILE' 파일이 없습니다."
    echo ""
    show_help
    exit 1
fi

# 환경변수 체크
if [ -z "$BASE_URL" ]; then
    echo "오류: BASE_URL 환경변수가 설정되지 않았습니다."
    echo "export BASE_URL=\"https://your-api.com/api\""
    exit 1
fi

# 결과 디렉토리
RESULTS_DIR="results"
mkdir -p "$RESULTS_DIR"
OUTPUT_FILE="$RESULTS_DIR/${SCENARIO}_$(date +%Y%m%d_%H%M%S).json"

echo "=========================================="
echo " 시나리오: $SCENARIO"
echo "=========================================="
echo "BASE_URL: $BASE_URL"
echo "JWT_TOKEN: ${JWT_TOKEN:+설정됨}${JWT_TOKEN:-미설정}"
echo "결과 파일: $OUTPUT_FILE"
echo ""

# 실행
k6 run --out json="$OUTPUT_FILE" "$SCRIPT_FILE"

echo ""
echo "완료! 결과: $OUTPUT_FILE"