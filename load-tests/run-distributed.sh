#!/bin/bash
#
# 분산 부하테스트 실행 스크립트 (SSH 방식)
# EC2 러너 3대에 SSH로 동시 실행
#
# 사용법:
#   ./run-distributed.sh <시나리오> [옵션]
#
# 시나리오:
#   표준 프로파일: smoke, load, stress, spike, soak
#   비즈니스:     guest-flow, user-flow, create-meeting, book-report, meeting-spike, meeting-lifecycle
#   RDS 타겟:     meeting-search, today-meetings, my-meetings-n1, join-meeting
#   서비스별:     chat-api, chat-ws, notification, cache-test, image-upload
#   기타:         custom <path>
#
# 옵션:
#   --pull                 실행 전 git pull
#   --prom                 Grafana 연동 (Prometheus remote write)
#   --status               러너 상태 확인
#   --stop                 러너 중지
#   --start                러너 시작
#   --kill                 실행 중인 k6 프로세스 종료
#   --result               최신 결과 확인
#
# 환경변수:
#   TOKEN_COUNT=50         /dev/tokens 발급 개수
#   K6_STAGES="1m:25,5m:25,1m:0"
#   K6_EXTRA_ARGS="--stage 1m:25 --stage 5m:25 --stage 1m:0"
#   WS_STAGES="1m:25,5m:25,1m:0"
#
# 예시:
#   ./run-distributed.sh smoke --pull --prom
#   ./run-distributed.sh load --prom
#   ./run-distributed.sh --stop

set -euo pipefail

# ── 설정 ──
AWS_PROFILE="${AWS_PROFILE:-doktori-first}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
SSH_KEY="${SSH_KEY:-~/.ssh/doktori-loadtest.pem}"
SSH_USER="ubuntu"
SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=5)
BASE_URL="${BASE_URL:-https://api.doktori.kr/api}"
WS_URL="${WS_URL:-wss://api.doktori.kr/ws/chat}"
TAG_KEY="Purpose"
TAG_VALUE="distributed-k6-loadtest"

# 러너 1의 Prometheus (Grafana 연동용)
PROM_URL="${PROM_URL:-http://13.124.202.148:9090}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REMOTE_ENV_VARS=(
  TOKEN_COUNT
  TOKEN_PAGE_SIZE
  TOKEN_OFFSET
  TOKEN_FETCH_TIMEOUT
  TEST_MEETING_ID
  TEST_MEETING_IDS
  TEST_ROUND_ID
  TEST_ROOM_IDS
  CACHE_MEETING_IDS
  CHAT_ROOM_IDS
  K6_STAGES
  CHAT_API_STAGES
  CHAT_API_START_VUS
  WS_STAGES
  WS_START_VUS
  MSG_INTERVAL
  MSG_MIN
  MSG_MAX
  WS_SESSION_MIN
  WS_SESSION_MAX
  SESSION_DURATION
  K6_EXTRA_ARGS
)

append_remote_env() {
  local cmd="$1"
  local var value quoted

  for var in "${REMOTE_ENV_VARS[@]}"; do
    value="${!var:-}"
    if [ -n "$value" ]; then
      printf -v quoted '%q' "$value"
      cmd="${cmd} && export ${var}=${quoted}"
    fi
  done

  echo "$cmd"
}

# ── 시나리오 매핑 ──
resolve_scenario() {
  case "$1" in
    # 표준 부하 프로파일
    smoke)             echo "k6/scenarios/smoke.js" ;;
    load)              echo "k6/scenarios/load.js" ;;
    stress)            echo "k6/scenarios/stress.js" ;;
    spike)             echo "k6/scenarios/spike.js" ;;
    soak)              echo "k6/scenarios/soak.js" ;;
    # 비즈니스 플로우
    guest-flow)        echo "k6/scenarios/guest-flow.js" ;;
    user-flow)         echo "k6/scenarios/user-flow.js" ;;
    create-meeting)    echo "k6/scenarios/create-meeting.js" ;;
    book-report)       echo "k6/scenarios/book-report.js" ;;
    meeting-spike)     echo "k6/scenarios/meeting-spike.js" ;;
    meeting-lifecycle) echo "k6/scenarios/meeting-lifecycle.js" ;;
    # RDS 타겟
    meeting-search)    echo "k6/scenarios/meeting-search.js" ;;
    today-meetings)    echo "k6/scenarios/today-meetings.js" ;;
    my-meetings-n1)    echo "k6/scenarios/my-meetings-n1.js" ;;
    join-meeting)      echo "k6/scenarios/join-meeting.js" ;;
    # 서비스별
    chat-api)          echo "k6/scenarios/chat-api.js" ;;
    chat-ws)           echo "k6/scenarios/chat-websocket.js" ;;
    notification)      echo "k6/scenarios/notification.js" ;;
    cache-test)        echo "k6/scenarios/cache-test.js" ;;
    image-upload)      echo "k6/scenarios/image-upload.js" ;;
    custom)            echo "$2" ;;
    *)                 echo "" ;;
  esac
}

# ── 러너 IP 조회 ──
get_runner_ips() {
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    ec2 describe-instances \
    --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].PublicIpAddress" \
    --output text
}

get_runner_ids() {
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    ec2 describe-instances \
    --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text
}

# ── SSH로 k6 실행 ──
run_on_runner() {
  local ip="$1"
  local scenario_file="$2"
  local do_pull="$3"
  local use_prom="$4"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)

  local cmd="cd /home/ubuntu/doktori-cloud/load-tests"

  if [ "$do_pull" = "true" ]; then
    cmd="${cmd} && git pull --ff-only"
  fi

  cmd="${cmd} && export BASE_URL=${BASE_URL}"
  cmd="${cmd} && export WS_URL=${WS_URL}"
  cmd=$(append_remote_env "$cmd")

  local k6_args=""
  if [ "$use_prom" = "true" ] && [ -n "$PROM_URL" ]; then
    cmd="${cmd} && export K6_PROMETHEUS_RW_SERVER_URL=${PROM_URL}/api/v1/write"
    cmd="${cmd} && export K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true"
    k6_args="--out experimental-prometheus-rw"
  fi

  cmd="${cmd} && k6 run ${k6_args} \${K6_EXTRA_ARGS:-} ${scenario_file} 2>&1 | tee /tmp/k6-${timestamp}.log"

  echo -e "${CYAN}[${ip}]${NC} 시작: ${scenario_file}"
  # shellcheck disable=SC2029  # cmd is intentionally built locally and expanded before SSH
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "${cmd}" &
}

# ── 메인 실행 ──
run_command() {
  local scenario_file="$1"
  local do_pull="$2"
  local use_prom="$3"

  local runner_ips
  runner_ips=$(get_runner_ips)

  if [ -z "$runner_ips" ]; then
    echo -e "${RED}실행 중인 러너가 없습니다.${NC}"
    exit 1
  fi

  local count
  count=$(echo "$runner_ips" | wc -w | tr -d ' ')

  # 러너 1 IP를 Prometheus URL로 자동 설정
  if [ "$use_prom" = "true" ] && [ -z "$PROM_URL" ]; then
    local first_ip
    first_ip=$(echo "$runner_ips" | awk '{print $1}')
    PROM_URL="http://${first_ip}:9090"
  fi

  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN} 분산 부하테스트 실행${NC}"
  echo -e "${GREEN}========================================${NC}"
  echo ""
  echo -e "시나리오:    ${CYAN}${scenario_file}${NC}"
  echo -e "BASE_URL:    ${BASE_URL}"
  echo -e "러너:        ${CYAN}${count}대${NC}"
  echo -e "Prometheus:  ${PROM_URL:-비활성}"
  echo ""

  for ip in $runner_ips; do
    echo -e "  ${CYAN}${ip}${NC}"
  done
  echo ""

  for ip in $runner_ips; do
    run_on_runner "$ip" "$scenario_file" "$do_pull" "$use_prom"
  done

  echo ""
  echo -e "${YELLOW}실행 중... Ctrl+C로 중단 가능${NC}"
  echo -e "Grafana: ${PROM_URL:-없음}"
  echo ""

  wait
  echo ""
  echo -e "${GREEN}전체 완료!${NC}"
}

# ── 테스트 중단 ──
kill_tests() {
  local runner_ips
  runner_ips=$(get_runner_ips)

  if [ -z "$runner_ips" ]; then
    echo -e "${RED}실행 중인 러너가 없습니다.${NC}"
    exit 1
  fi

  echo -e "${YELLOW}k6 프로세스 종료 중...${NC}"
  for ip in $runner_ips; do
    # shellcheck disable=SC2029  # ${ip} intentionally expands locally for the echo label
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "pkill -f k6 2>/dev/null; echo \"killed on ${ip}\"" &
  done
  wait
  echo -e "${GREEN}전체 중단 완료.${NC}"
}

# ── 결과 확인 ──
show_results() {
  local runner_ips
  runner_ips=$(get_runner_ips)

  if [ -z "$runner_ips" ]; then
    echo -e "${RED}실행 중인 러너가 없습니다.${NC}"
    exit 1
  fi

  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN} 최신 부하테스트 결과${NC}"
  echo -e "${GREEN}========================================${NC}"
  echo ""

  for ip in $runner_ips; do
    echo -e "${CYAN}=== Runner: ${ip} ===${NC}"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" '
      LATEST=$(ls -t /tmp/k6-*.log 2>/dev/null | head -1)
      if [ -z "$LATEST" ]; then
        echo "결과 파일 없음"
      else
        echo "파일: $LATEST"
        echo "크기: $(wc -c < "$LATEST") bytes"
        echo ""
        grep -E "(checks|http_req_duration|http_req_failed|errors|http_reqs|vus_max|iterations|running.*VUs|thresholds)" "$LATEST" | tail -15
      fi
    ' 2>&1
    echo ""
  done
}

# ── 러너 관리 ──
manage_runners() {
  local action="$1"
  local ids
  ids=$(get_runner_ids)

  if [ -z "$ids" ]; then
    echo -e "${RED}러너가 없습니다.${NC}"
    exit 1
  fi

  # ids는 공백 구분 인스턴스 ID 목록 → 배열로 분리
  read -ra id_array <<< "$ids"

  case "$action" in
    start)
      echo -e "${YELLOW}러너 시작 중...${NC}"
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        ec2 start-instances --instance-ids "${id_array[@]}" > /dev/null
      echo -e "${GREEN}시작됨. 1-2분 후 SSH 접속 가능.${NC}"
      ;;
    stop)
      echo -e "${YELLOW}러너 중지 중...${NC}"
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        ec2 stop-instances --instance-ids "${id_array[@]}" > /dev/null
      echo -e "${GREEN}중지됨.${NC}"
      ;;
    status)
      echo -e "${GREEN}러너 상태:${NC}"
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        ec2 describe-instances \
        --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
        --query "Reservations[].Instances[].[Tags[?Key=='Name'].Value|[0],PublicIpAddress,State.Name]" \
        --output table
      ;;
  esac
}

# ── 도움말 ──
show_help() {
  head -38 "$0" | tail -37
}

# ── 파싱 ──
ACTION="${1:-help}"
DO_PULL="false"
USE_PROM="false"
CUSTOM_PATH=""

shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --pull)   DO_PULL="true"; shift ;;
    --prom)   USE_PROM="true"; shift ;;
    --kill)   kill_tests; exit 0 ;;
    --stop)   manage_runners stop; exit 0 ;;
    --start)  manage_runners start; exit 0 ;;
    --status) manage_runners status; exit 0 ;;
    --result) show_results; exit 0 ;;
    *)        CUSTOM_PATH="$1"; shift ;;
  esac
done

case "$ACTION" in
  help|-h|--help) show_help ;;
  --kill)   kill_tests ;;
  --stop)   manage_runners stop ;;
  --start)  manage_runners start ;;
  --status) manage_runners status ;;
  --result) show_results ;;
  custom)
    [ -z "$CUSTOM_PATH" ] && echo "커스텀 시나리오 경로를 지정하세요" && exit 1
    run_command "$CUSTOM_PATH" "$DO_PULL" "$USE_PROM"
    ;;
  *)
    SCENARIO_FILE=$(resolve_scenario "$ACTION" "$CUSTOM_PATH")
    if [ -z "$SCENARIO_FILE" ]; then
      echo -e "${RED}알 수 없는 시나리오: ${ACTION}${NC}"
      show_help
      exit 1
    fi
    run_command "$SCENARIO_FILE" "$DO_PULL" "$USE_PROM"
    ;;
esac
