#!/bin/bash
#
# 분산 부하테스트 실행 스크립트
# EC2 러너 3대에 SSM Run Command로 동시 실행
#
# 사용법:
#   ./run-distributed.sh <시나리오> [옵션]
#
# 시나리오:
#   smoke         Smoke 테스트 (5 VU, 1분)
#   load          Load 테스트 (50→100 VU, 멀티유저)
#   stress        Stress 테스트 (100→500 VU)
#   spike         Spike 테스트 (100→500→100 VU)
#   soak          Soak 테스트 (50 VU, 1시간)
#   guest-flow    비회원 탐색
#   user-flow     로그인 사용자
#   meeting-search 모임 검색 병목
#   chat-api      채팅 REST API
#   chat-ws       채팅 WebSocket
#   notification  알림 (SSE + API)
#   custom <path> 커스텀 시나리오 경로
#
# 옵션:
#   --status <command-id>  이전 실행 결과 확인
#   --logs <instance-id>   특정 러너 로그 확인
#   --pull                 실행 전 git pull (최신 코드)
#
# 예시:
#   ./run-distributed.sh load
#   ./run-distributed.sh stress --pull
#   ./run-distributed.sh custom k6/scenarios/my-meetings-n1.js
#   ./run-distributed.sh --status 12345-abcde
#

set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-doktori-first}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
BASE_URL="${BASE_URL:-https://api.doktori.kr/api}"
WS_URL="${WS_URL:-wss://api.doktori.kr/ws/chat}"
TAG_KEY="Purpose"
TAG_VALUE="distributed-k6-loadtest"
TIMEOUT=3600  # 1시간 (soak 대비)

# Prometheus remote write URL (러너 1의 Prometheus)
# apply 후 terraform output prometheus_url 로 IP 확인하여 설정
PROM_REMOTE_WRITE_URL="${PROM_REMOTE_WRITE_URL:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 시나리오 → 파일 매핑
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
    *)
      echo ""
      ;;
  esac
}

# 러너 인스턴스 ID 조회
get_runner_ids() {
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    ec2 describe-instances \
    --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text
}

# SSM Run Command 실행
run_command() {
  local scenario_file="$1"
  local do_pull="${2:-false}"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  local result_file="/tmp/k6-${timestamp}.log"

  # 러너에 있는 run-on-runner.sh를 호출 (SSM JSON 이스케이프 문제 회피)
  local runner_script="/home/ubuntu/5-team-service-cloud/load-tests/run-on-runner.sh"
  local args="${scenario_file}"

  if [ "$do_pull" = "true" ]; then
    args="${args} --pull"
  fi

  if [ -n "$PROM_REMOTE_WRITE_URL" ]; then
    args="${args} --prom ${PROM_REMOTE_WRITE_URL}"
  fi

  local commands="export HOME=/root && bash ${runner_script} ${args}"

  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN} 분산 부하테스트 실행${NC}"
  echo -e "${GREEN}========================================${NC}"
  echo ""
  echo -e "시나리오:  ${CYAN}${scenario_file}${NC}"
  echo -e "BASE_URL:  ${BASE_URL}"
  echo -e "WS_URL:    ${WS_URL}"
  echo -e "결과 파일: ${result_file}"
  echo ""

  # 러너 확인
  local runner_ids
  runner_ids=$(get_runner_ids)
  if [ -z "$runner_ids" ]; then
    echo -e "${RED}실행 중인 러너가 없습니다. terraform apply 먼저 실행하세요.${NC}"
    exit 1
  fi

  local runner_count
  runner_count=$(echo "$runner_ids" | wc -w | tr -d ' ')
  echo -e "러너:      ${CYAN}${runner_count}대${NC} (${runner_ids})"
  echo ""

  # SSM 등록 확인
  echo -e "${YELLOW}SSM 등록 상태 확인 중...${NC}"
  local ssm_ids
  ssm_ids=$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$(echo $runner_ids | tr ' ' ',')" \
    --query "InstanceInformationList[].InstanceId" \
    --output text 2>/dev/null || true)

  if [ -z "$ssm_ids" ]; then
    echo -e "${RED}SSM에 등록된 인스턴스가 없습니다. 부팅 완료까지 1-2분 대기하세요.${NC}"
    exit 1
  fi

  local ssm_count
  ssm_count=$(echo "$ssm_ids" | wc -w | tr -d ' ')
  echo -e "SSM 등록:  ${CYAN}${ssm_count}대${NC}"
  echo ""

  # 실행
  echo -e "${YELLOW}명령 전송 중...${NC}"
  local command_id
  command_id=$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    ssm send-command \
    --targets "Key=tag:${TAG_KEY},Values=${TAG_VALUE}" \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\":[\"${commands}\"]}" \
    --timeout-seconds "$TIMEOUT" \
    --comment "k6 distributed: ${scenario_file}" \
    --query "Command.CommandId" \
    --output text)

  echo ""
  echo -e "${GREEN}실행 시작!${NC}"
  echo -e "Command ID: ${CYAN}${command_id}${NC}"
  echo ""
  echo "상태 확인:"
  echo -e "  ${CYAN}$0 --status ${command_id}${NC}"
  echo ""
  echo "개별 러너 로그:"
  for id in $runner_ids; do
    echo -e "  ${CYAN}$0 --logs ${id}${NC}"
  done
  echo ""
  echo "SSM 직접 접속:"
  for id in $runner_ids; do
    echo -e "  aws --profile ${AWS_PROFILE} ssm start-session --target ${id}"
  done
}

# 실행 상태 확인
check_status() {
  local command_id="$1"

  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN} 실행 상태: ${command_id}${NC}"
  echo -e "${GREEN}========================================${NC}"
  echo ""

  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    ssm list-command-invocations \
    --command-id "$command_id" \
    --query "CommandInvocations[].{Instance:InstanceId,Status:Status,Start:RequestedDateTime}" \
    --output table
}

# 러너 로그 확인
check_logs() {
  local instance_id="$1"

  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN} 러너 로그: ${instance_id}${NC}"
  echo -e "${GREEN}========================================${NC}"
  echo ""

  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    ssm start-session --target "$instance_id"
}

# 러너 시작/중지
manage_runners() {
  local action="$1"
  local runner_ids
  runner_ids=$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    ec2 describe-instances \
    --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text)

  if [ -z "$runner_ids" ]; then
    echo -e "${RED}러너가 없습니다.${NC}"
    exit 1
  fi

  case "$action" in
    start)
      echo -e "${YELLOW}러너 시작 중...${NC}"
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        ec2 start-instances --instance-ids $runner_ids
      echo -e "${GREEN}시작됨. SSM 등록까지 1-2분 소요.${NC}"
      ;;
    stop)
      echo -e "${YELLOW}러너 중지 중...${NC}"
      aws --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        ec2 stop-instances --instance-ids $runner_ids
      echo -e "${GREEN}중지됨.${NC}"
      ;;
  esac
}

# 도움말
show_help() {
  head -35 "$0" | tail -33
}

# ── 메인 ──

ACTION="${1:-help}"
DO_PULL="false"

# 옵션 파싱
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --pull) DO_PULL="true"; shift ;;
    --status) check_status "$2"; exit 0 ;;
    --logs) check_logs "$2"; exit 0 ;;
    --start) manage_runners start; exit 0 ;;
    --stop) manage_runners stop; exit 0 ;;
    *) break ;;
  esac
done

case "$ACTION" in
  help|-h|--help)
    show_help
    ;;
  --status)
    check_status "$1"
    ;;
  --logs)
    check_logs "$1"
    ;;
  --start)
    manage_runners start
    ;;
  --stop)
    manage_runners stop
    ;;
  custom)
    SCENARIO_FILE="${1:?커스텀 시나리오 경로를 지정하세요}"
    run_command "$SCENARIO_FILE" "$DO_PULL"
    ;;
  *)
    SCENARIO_FILE=$(resolve_scenario "$ACTION")
    if [ -z "$SCENARIO_FILE" ]; then
      echo -e "${RED}알 수 없는 시나리오: ${ACTION}${NC}"
      echo ""
      show_help
      exit 1
    fi
    run_command "$SCENARIO_FILE" "$DO_PULL"
    ;;
esac