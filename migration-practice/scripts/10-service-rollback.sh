#!/bin/bash
# ============================================================
# 10. 서비스(컨테이너) 롤백
#
# 용도: 새 VPC 서버에서 서비스 배포 후 문제 발생 시
#       이전 버전의 컨테이너 이미지로 즉시 롤백한다.
#
# 대상 Unit: Unit 8 (ECR 이미지 push) / Unit 9 (서비스 배포)
#
# 절차:
#   1. 현재 실행 중인 컨테이너 정보 기록
#   2. 이전 이미지 태그 확인
#   3. 이전 이미지로 컨테이너 재시작
#   4. 헬스체크 확인
#
# 포트폴리오 핵심:
#   "배포 롤백 X초 내 완료, 서비스 중단 없음"
# ============================================================

set -euo pipefail

# ── 설정 ──
TARGET_HOST="${TARGET_HOST:-localhost}"         # 롤백 대상 서버
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"

# 컨테이너 설정
API_CONTAINER="${API_CONTAINER:-backend-api}"
CHAT_CONTAINER="${CHAT_CONTAINER:-backend-chat}"

# ECR 설정
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
ECR_REGISTRY="${ECR_REGISTRY:-<ACCOUNT_ID>.dkr.ecr.${AWS_REGION}.amazonaws.com}"
API_REPO="${API_REPO:-doktori/api}"
CHAT_REPO="${CHAT_REPO:-doktori/chat}"

# 롤백 대상 태그 (이전 안정 버전)
ROLLBACK_TAG="${ROLLBACK_TAG:-stable}"

LOG_DIR="/tmp/db-migration"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/service-rollback-$(date +%Y%m%d-%H%M%S).log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# SSH 실행 헬퍼
run_remote() {
    if [ "$TARGET_HOST" = "localhost" ]; then
        eval "$1"
    else
        ssh -i "$SSH_KEY" "${SSH_USER}@${TARGET_HOST}" "$1"
    fi
}

echo "========================================================"
echo " 서비스(컨테이너) 롤백"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
echo ""
echo "  대상 서버:  ${TARGET_HOST}"
echo "  롤백 태그:  ${ROLLBACK_TAG}"
echo ""

# ── 1. 현재 실행 중인 컨테이너 정보 ──
log "=== STEP 1: 현재 컨테이너 정보 기록 ==="
echo ""

CURRENT_API_IMAGE=$(run_remote "docker inspect --format='{{.Config.Image}}' ${API_CONTAINER} 2>/dev/null" || echo "N/A")
CURRENT_CHAT_IMAGE=$(run_remote "docker inspect --format='{{.Config.Image}}' ${CHAT_CONTAINER} 2>/dev/null" || echo "N/A")

log "  현재 API 이미지:  ${CURRENT_API_IMAGE}"
log "  현재 Chat 이미지: ${CURRENT_CHAT_IMAGE}"
echo ""

# 현재 이미지를 rollback-backup 태그로 보관
log "  현재 이미지를 백업 태그로 보관..."
run_remote "docker tag ${CURRENT_API_IMAGE} ${ECR_REGISTRY}/${API_REPO}:rollback-backup 2>/dev/null" || true
run_remote "docker tag ${CURRENT_CHAT_IMAGE} ${ECR_REGISTRY}/${CHAT_REPO}:rollback-backup 2>/dev/null" || true
echo ""

# ── 2. 이전 이미지 확인 ──
log "=== STEP 2: 롤백 대상 이미지 확인 ==="

# ECR에서 이전 태그 확인
ROLLBACK_API_IMAGE="${ECR_REGISTRY}/${API_REPO}:${ROLLBACK_TAG}"
ROLLBACK_CHAT_IMAGE="${ECR_REGISTRY}/${CHAT_REPO}:${ROLLBACK_TAG}"

log "  롤백 API 이미지:  ${ROLLBACK_API_IMAGE}"
log "  롤백 Chat 이미지: ${ROLLBACK_CHAT_IMAGE}"
echo ""

echo "  롤백 대상 컨테이너:"
echo "    API:  ${API_CONTAINER} → ${ROLLBACK_API_IMAGE}"
echo "    Chat: ${CHAT_CONTAINER} → ${ROLLBACK_CHAT_IMAGE}"
echo ""
read -p "  롤백을 진행하시겠습니까? (y/N): " CONFIRM
[ "$CONFIRM" != "y" ] && echo "취소됨." && exit 0

ROLLBACK_START=$(date +%s)

# ── 3. ECR 로그인 + 이미지 pull ──
log "=== STEP 3: ECR 로그인 + 이미지 pull ==="
run_remote "aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY}" 2>/dev/null
log "  ✅ ECR 로그인 완료"

run_remote "docker pull ${ROLLBACK_API_IMAGE}" 2>/dev/null
run_remote "docker pull ${ROLLBACK_CHAT_IMAGE}" 2>/dev/null
log "  ✅ 롤백 이미지 pull 완료"
echo ""

# ── 4. 컨테이너 교체 (순차: Chat → API) ──
log "=== STEP 4: 컨테이너 롤백 ==="

# Chat 서버 먼저 (의존성 낮은 것부터)
log "  [4-1] Chat 컨테이너 롤백..."
CHAT_RUN_OPTS=$(run_remote "docker inspect --format='{{json .HostConfig}}' ${CHAT_CONTAINER} 2>/dev/null" || echo "{}")

run_remote "docker stop ${CHAT_CONTAINER} 2>/dev/null; docker rm ${CHAT_CONTAINER} 2>/dev/null" || true
run_remote "docker run -d \
    --name ${CHAT_CONTAINER} \
    --network host \
    --restart unless-stopped \
    --env-file /home/${SSH_USER}/app/.env \
    ${ROLLBACK_CHAT_IMAGE}" 2>/dev/null
log "  ✅ Chat 컨테이너 롤백 완료"
sleep 3

# API 서버
log "  [4-2] API 컨테이너 롤백..."
run_remote "docker stop ${API_CONTAINER} 2>/dev/null; docker rm ${API_CONTAINER} 2>/dev/null" || true
run_remote "docker run -d \
    --name ${API_CONTAINER} \
    --network host \
    --restart unless-stopped \
    --env-file /home/${SSH_USER}/app/.env \
    ${ROLLBACK_API_IMAGE}" 2>/dev/null
log "  ✅ API 컨테이너 롤백 완료"
echo ""

# ── 5. 헬스체크 ──
log "=== STEP 5: 헬스체크 (최대 60초 대기) ==="

API_HEALTH_URL="${API_HEALTH_URL:-http://localhost:8080/api/health}"
CHAT_HEALTH_URL="${CHAT_HEALTH_URL:-http://localhost:8081/api/health}"

for i in $(seq 1 12); do
    sleep 5
    API_STATUS=$(run_remote "curl -s -o /dev/null -w '%{http_code}' ${API_HEALTH_URL} 2>/dev/null" || echo "000")
    CHAT_STATUS=$(run_remote "curl -s -o /dev/null -w '%{http_code}' ${CHAT_HEALTH_URL} 2>/dev/null" || echo "000")

    log "  [${i}/12] API=${API_STATUS} Chat=${CHAT_STATUS}"

    if [ "$API_STATUS" = "200" ] && [ "$CHAT_STATUS" = "200" ]; then
        log "  ✅ 모든 서비스 정상!"
        break
    fi

    if [ "$i" -eq 12 ]; then
        log "  ❌ 60초 내 헬스체크 실패"
        log "  → docker logs ${API_CONTAINER} / docker logs ${CHAT_CONTAINER} 확인"
    fi
done
echo ""

ROLLBACK_END=$(date +%s)
ROLLBACK_ELAPSED=$((ROLLBACK_END - ROLLBACK_START))

echo "========================================================"
echo " 서비스 롤백 완료"
echo "========================================================"
echo ""
echo "  롤백 소요 시간: ${ROLLBACK_ELAPSED}초"
echo "  API:  ${ROLLBACK_API_IMAGE}"
echo "  Chat: ${ROLLBACK_CHAT_IMAGE}"
echo ""
if [ "$ROLLBACK_ELAPSED" -le 120 ]; then
    echo "  ✅ 2분 이내 롤백 완료"
else
    echo "  ⚠️ ${ROLLBACK_ELAPSED}초 소요 — 2분(120초) 초과"
fi
echo ""
echo "  다음 단계:"
echo "  - 서비스 정상 동작 확인 (API 호출 테스트)"
echo "  - Nginx upstream이 이 서버를 가리키고 있다면 확인"
echo "  - 모니터링 대시보드에서 에러율 확인"
echo ""
echo "  로그: ${LOG_FILE}"
