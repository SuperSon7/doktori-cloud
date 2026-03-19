
#!/bin/bash
#
# 분산 부하테스트 실행 스크립트 (SSH 방식)
# EC2 러너 3대에 SSH로 동시 실행
#
# 사용법:
#   ./run-distributed.sh <시나리오> [옵션]
#
# 시나리오:
#   smoke, load, stress, spike, soak
#   guest-flow, user-flow, meeting-search, join-meeting
#   chat-api, chat-ws, notification, cache-test
#   image-upload, create-meeting
#   custom <path>
#
# 옵션:
#   --pull                 실행 전 git pull
#   --prom                 Grafana 연동 (Prometheus remote write)
#   --status               러너 상태 확인
#   --stop                 러너 중지
#   --start                러너 시작
#
# 예시:
#   ./run-distributed.sh smoke --pull --prom
#   ./run-distributed.sh load --prom
#   ./run-distributed.sh stress
#   ./run-distributed.sh --stop

set -euo pipefail

# ── 설정 ──
AWS_PROFILE="${AWS_PROFILE:-doktori-first}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
SSH_KEY="${SSH_KEY:-~/.ssh/doktori-loadtest.pem}"
SSH_USER="ubuntu"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=5"
BASE_URL="${BASE_URL:-https://api.doktori.kr/api}"
WS_URL="${WS_URL:-wss://api.doktori.kr/ws/chat}"
TAG_KEY="Purpose"
TAG_VALUE="distributed-k6-loadtest"

# 러너 1의 Prometheus (Grafana 연동용)
# Grafana+Prometheus가 있는 러너 IP — terraform output grafana_url로 확인
PROM_URL="${PROM_URL:-http://13.124.202.148:9090}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── 시나리오 매핑 ──
resolve_scenario() {
  case "$1" in
    smoke)          echo "k6/scenarios/smoke.js" ;;
    load)           echo "k6/scenarios/load.js" ;;
    stress)         echo "k6/scenarios/stress.js" ;;
    spike)          echo "k6/scenarios/spike.js" ;;
    soak)           echo "k6/scenarios/soak.js" ;;
    guest-flow)     echo "k6/scenarios/guest-flow.js" ;;
    user-flow)      echo "k6/scenarios/user-flow.js" ;;
    meeting-search) echo "k6/scenarios/meeting-search.js" ;;
    join-meeting)   echo "k6/scenarios/join-meeting.js" ;;
    chat-api)       echo "k6/scenarios/chat-api.js" ;;
    chat-ws)        echo "k6/scenarios/chat-websocket.js" ;;
    notification)   echo "k6/scenarios/notification.js" ;;
    cache-test)     echo "k6/scenarios/cache-test.js" ;;
    image-upload)   echo "k6/scenarios/image-upload.js" ;;
    create-meeting) echo "k6/scenarios/create-meeting.js" ;;
    custom)         echo "$2" ;;
    *) echo "" ;;
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

  local cmd="cd /home/ubuntu/5-team-service-cloud/load-tests"

  if [ "$do_pull" = "true" ]; then
    cmd="${cmd} && git pull --ff-only"
  fi

  cmd="${cmd} && export BASE_URL=${BASE_URL}"
  cmd="${cmd} && export WS_URL=${WS_URL}"

  local k6_args=""
  if [ "$use_prom" = "true" ] && [ -n "$PROM_URL" ]; then
    cmd="${cmd} && export K6_PROMETHEUS_RW_SERVER_URL=${PROM_URL}/api/v1/write"
    k6_args="--out experimental-prometheus-rw"
  fi

  cmd="${cmd} && k6 run ${k6_args} ${scenario_file} 2>&1 | tee /tmp/k6-${timestamp}.log"

  echo -e "${CYAN}[${ip}]${NC} 시작: ${scenario_file}"
  ssh ${SSH_OPTS} ${SSH_USER}@${ip} "${cmd}" &
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

  # 3대 동시 실행 (백그라운드)
  for ip in $runner_ips; do
    run_on_runner "$ip" "$scenario_file" "$do_pull" "$use_prom"
  done

  echo ""
  echo -e "${YELLOW}실행 중... Ctrl+C로 중단 가능${NC}"
  echo -e "Grafana: ${PROM_URL:-없음}"
  echo ""

  # 모든 백그라운드 프로세스 대기
  wait
  echo ""
  echo -e "${GREEN}전체 완료!${NC}"
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
    ssh ${SSH_OPTS} ${SSH_USER}@${ip} "
      LATEST=\$(ls -t /tmp/k6-*.log 2>/dev/null | head -1)
      if [ -z \"\$LATEST\" ]; then
        echo '결과 파일 없음'
      else
        echo \"파일: \$LATEST\"
        echo \"크기: \$(wc -c < \$LATEST) bytes\"
        echo ''
        grep -E '(checks|http_req_duration|http_req_failed|errors|http_reqs|vus_max|iterations|running.*VUs|thresholds)' \$LATEST | tail -15
      fi
    " 2>&1
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

  case "$action" in
    start)
      echo -e "${YELLOW}러너 시작 중...${NC}"
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        ec2 start-instances --instance-ids $ids > /dev/null
      echo -e "${GREEN}시작됨. 1-2분 후 SSH 접속 가능.${NC}"
      ;;
    stop)
      echo -e "${YELLOW}러너 중지 중...${NC}"
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        ec2 stop-instances --instance-ids $ids > /dev/null
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
  head -30 "$0" | tail -28
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
    --stop)   manage_runners stop; exit 0 ;;
    --start)  manage_runners start; exit 0 ;;
    --status) manage_runners status; exit 0 ;;
    --result) show_results; exit 0 ;;
    *)        CUSTOM_PATH="$1"; shift ;;
  esac
done

case "$ACTION" in
  help|-h|--help) show_help ;;
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