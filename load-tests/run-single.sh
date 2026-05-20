#!/bin/bash
#
# 단일 시나리오 실행 스크립트
#
# 사용법:
#   export BASE_URL="https://api.doktori.kr/api"
#   ./run-single.sh <시나리오> [--prom]
#
# 옵션:
#   --prom    Grafana 연동 (Prometheus remote write)
#             PROM_URL 환경변수 또는 기본값 http://localhost:9090 사용
#
# ─── 표준 부하 프로파일 ───────────────────────────────────────
#   smoke         기본 동작 확인 (저부하, 1~5 VU)
#   load          정상 트래픽 종합 테스트 (50~100 VU)
#   stress        한계점 탐색 — 점진적 증가 (100~500 VU)
#   spike         급격한 트래픽 스파이크 내성 (500 VU)
#   soak          1시간 장시간 안정성 — 메모리/커넥션 누수 탐지
#
# ─── 비즈니스 플로우 ──────────────────────────────────────────
#   guest-flow    비회원 탐색 패턴 (추천/모임목록/검색)
#   user-flow     로그인 사용자 일상 패턴 (내모임/알림/리뷰)
#   create-meeting 모임 생성 — Kakao BookAPI + S3 + DB 트랜잭션
#   book-report   독후감 작성/조회 (TEST_ROUND_ID 필요)
#   meeting-spike 20시 모임 시작 시간대 동시 접속 시뮬레이션
#   meeting-lifecycle 30분 토론 전체 사이클 (WS + REST 복합)
#
# ─── RDS 타겟 ─────────────────────────────────────────────────
#   meeting-search  검색 서브쿼리 2회 중복 — MeetingRepositoryImpl 병목
#   today-meetings  DATE() 함수 인덱스 무효화 — 저녁 피크 시뮬레이션
#   my-meetings-n1  N+1 쿼리 — 목록 10건 시 추가 쿼리 20건
#   join-meeting    정원 레이스 컨디션 — SELECT/UPDATE 간 타이밍 이슈
#
# ─── 서비스별 ────────────────────────────────────────────────
#   chat-api      Chat 서버 REST — 방생성/입장/메시지/투표/요약
#   chat-websocket STOMP WebSocket 동시 연결 (WS_URL 필요)
#   notification  SSE 동시 연결 한계 + 알림 읽기/쓰기
#   cache-test    Nginx 캐시 HIT율 검증 (비인증 공개 API)
#   image-upload  S3 Presigned URL 업로드 단독
#
# 예시:
#   ./run-single.sh smoke
#   ./run-single.sh chat-api --prom
#   PROM_URL=http://13.124.202.148:9090 ./run-single.sh chat-api --prom

set -e

PROM_URL="${PROM_URL:-http://localhost:9090}"
USE_PROM="false"
SCENARIO=""

for arg in "$@"; do
  case "$arg" in
    --prom) USE_PROM="true" ;;
    *)      SCENARIO="$arg" ;;
  esac
done

show_help() {
    head -60 "$0" | tail -59
}

if [ -z "$SCENARIO" ]; then
    show_help
    exit 1
fi

SCRIPT_FILE="k6/scenarios/${SCENARIO}.js"

if [ ! -f "$SCRIPT_FILE" ]; then
    echo "오류: '$SCRIPT_FILE' 파일이 없습니다."
    echo ""
    echo "사용 가능한 시나리오:"
    find k6/scenarios -maxdepth 1 -name '*.js' -print0 | xargs -0 -I{} basename {} .js | sort | sed 's/^/  - /'
    exit 1
fi

if [ -z "$BASE_URL" ]; then
    echo "오류: BASE_URL 환경변수가 설정되지 않았습니다."
    echo "export BASE_URL=\"https://api.doktori.kr/api\""
    exit 1
fi

RESULTS_DIR="results"
mkdir -p "$RESULTS_DIR"
OUTPUT_FILE="$RESULTS_DIR/${SCENARIO}_$(date +%Y%m%d_%H%M%S).json"

echo "=========================================="
echo " 시나리오: $SCENARIO"
echo "=========================================="
echo "BASE_URL:   $BASE_URL"
echo "TOKEN_COUNT:${TOKEN_COUNT:-기본값}"
echo "Prometheus: ${USE_PROM} (${PROM_URL})"
echo "결과 파일:  $OUTPUT_FILE"
echo ""

K6_ARGS=("--out" "json=${OUTPUT_FILE}")

if [ "$USE_PROM" = "true" ]; then
    export K6_PROMETHEUS_RW_SERVER_URL="${PROM_URL}/api/v1/write"
    export K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true
    K6_ARGS+=("--out" "experimental-prometheus-rw")
    echo "Grafana 연동: ${K6_PROMETHEUS_RW_SERVER_URL}"
    echo ""
fi

k6 run "${K6_ARGS[@]}" "$SCRIPT_FILE"

echo ""
echo "완료! 결과: $OUTPUT_FILE"
