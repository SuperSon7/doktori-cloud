#!/bin/bash
set -e

DEV_INSTANCE_TAG_ENV="dev"
DEV_INSTANCE_TAG_SVC="app"
REGION="ap-northeast-2"

echo ">> backend 재생성 + nginx reload 명령 전송 중..."
CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Environment,Values=${DEV_INSTANCE_TAG_ENV}" "Key=tag:Service,Values=${DEV_INSTANCE_TAG_SVC}" \
  --parameters '{"commands":[
    "set -e",
    "cd /home/ubuntu/app",
    "sudo -u ubuntu docker compose pull backend",
    "sudo -u ubuntu docker compose up -d --no-deps --force-recreate backend",
    "for i in $(seq 1 20); do sudo -u ubuntu docker compose exec -T backend wget -qO- http://localhost:8080/api/health > /dev/null 2>&1 && break; echo \"  waiting... ($i/20)\"; sleep 3; done",
    "sudo -u ubuntu docker compose exec -T nginx nginx -s reload",
    "echo done"
  ]}' \
  --timeout-seconds 120 \
  --region "$REGION" \
  --comment "reload dev backend" \
  --query "Command.CommandId" \
  --output text)

echo ">> SSM Command: $CMD_ID"
echo ">> 결과 대기 중..."

for i in $(seq 1 30); do
  sleep 4
  STATUS=$(aws ssm list-command-invocations \
    --command-id "$CMD_ID" \
    --region "$REGION" \
    --query "CommandInvocations[0].Status" \
    --output text 2>/dev/null || echo "Pending")
  echo "  [$i/30] $STATUS"
  case "$STATUS" in
    Success)
      echo ""
      echo "== 실행 결과 =="
      aws ssm list-command-invocations --command-id "$CMD_ID" --details \
        --region "$REGION" \
        --query "CommandInvocations[0].CommandPlugins[0].Output" --output text
      exit 0 ;;
    Failed|Cancelled|TimedOut|DeliveryTimedOut)
      echo ""
      echo "== 실패 =="
      aws ssm list-command-invocations --command-id "$CMD_ID" --details \
        --region "$REGION" \
        --query "CommandInvocations[0].CommandPlugins[0].Output" --output text
      exit 1 ;;
  esac
done
echo ">> 타임아웃"
exit 1