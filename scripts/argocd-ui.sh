#!/usr/bin/env bash
# =============================================================================
# ArgoCD UI 접근 스크립트
#
# 사용법:
#   ./scripts/argocd-ui.sh                    # 자동으로 마스터 인스턴스 탐색
#   ./scripts/argocd-ui.sh i-0abc123def456    # 인스턴스 ID 직접 지정
#
# 동작:
#   1. SSM send-command로 마스터에 kubectl port-forward 띄움
#   2. SSM 포트포워딩으로 로컬:8443 → 마스터:8443 연결
#   3. 브라우저에서 https://localhost:8443 접근
#
# 종료: Ctrl+C
# =============================================================================
set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8443}"
REMOTE_PORT="8443"

cleanup() {
  echo ""
  echo "정리 중... 마스터의 port-forward 종료"
  if [ -n "${INSTANCE_ID:-}" ]; then
    aws ssm send-command \
      --instance-ids "$INSTANCE_ID" \
      --document-name "AWS-RunShellScript" \
      --parameters '{"commands":["pkill -f \"port-forward svc/argocd-server\" || true"]}' \
      --output text > /dev/null 2>&1 || true
  fi
  echo "종료됨."
}
trap cleanup EXIT

# --- 인스턴스 ID 확인 ---
if [ -n "${1:-}" ]; then
  INSTANCE_ID="$1"
else
  echo "마스터 인스턴스 검색 중..."
  INSTANCE_ID=$(aws ec2 describe-instances \
    --filters \
      "Name=tag:Name,Values=*k8s-master*" \
      "Name=tag:Role,Values=k8s-cp" \
      "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null)

  if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
    echo "[ERROR] 마스터 인스턴스를 찾을 수 없습니다."
    echo "  ./scripts/argocd-ui.sh <INSTANCE_ID>"
    exit 1
  fi
fi

echo "============================================="
echo " ArgoCD UI 접근"
echo "============================================="
echo "  Instance : ${INSTANCE_ID}"
echo "  Local    : https://localhost:${LOCAL_PORT}"
echo "  Username : admin"
echo "============================================="
echo ""

# --- 1. 마스터에서 port-forward 시작 ---
echo "[1/2] 마스터에서 port-forward 시작..."

# 기존 프로세스 정리 후 새로 시작
COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["pkill -f \"port-forward svc/argocd-server\" || true","sleep 1","su - ubuntu -c \"KUBECONFIG=/home/ubuntu/.kube/config nohup kubectl port-forward svc/argocd-server -n argocd '"${REMOTE_PORT}"':443 --address=127.0.0.1 > /tmp/argocd-pf.log 2>&1 & disown\"","sleep 3","if ss -tlnp | grep -q '"${REMOTE_PORT}"'; then echo PORT_OK; else echo PORT_FAIL; cat /tmp/argocd-pf.log 2>/dev/null; fi"]}' \
  --comment "ArgoCD port-forward" \
  --query 'Command.CommandId' \
  --output text)

echo "  → 명령 실행 대기..."
aws ssm wait command-executed \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" 2>/dev/null || true

# 결과 확인
RESULT=$(aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' \
  --output text 2>/dev/null || echo "")

if echo "$RESULT" | grep -q "PORT_OK"; then
  echo "  → port-forward 정상 시작됨"
else
  echo "  [WARN] port-forward 상태 불확실: ${RESULT}"
  echo "  → 계속 진행합니다..."
fi

# --- 2. SSM 포트포워딩 ---
echo ""
echo "[2/2] SSM 포트포워딩 연결..."
echo ""
echo "  → https://localhost:${LOCAL_PORT} 에서 ArgoCD UI 접근"
echo "  → 종료: Ctrl+C"
echo ""

aws ssm start-session \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"${REMOTE_PORT}\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
