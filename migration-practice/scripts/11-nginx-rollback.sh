#!/bin/bash
# ============================================================
# 11. Nginx 라우팅 롤백
#
# 용도: Nginx upstream을 새 VPC에서 구 Lightsail로 원복
#       DNS 전환 전 Nginx 레이어에서 즉시 롤백한다.
#
# 대상 Unit: Unit 10 (Nginx 라우팅 전환)
#
# 절차:
#   1. 현재 Nginx upstream 설정 백업
#   2. 이전 upstream 설정 복원
#   3. nginx -t (구문 검사)
#   4. nginx -s reload
#   5. 라우팅 정상 확인
#
# 포트폴리오 핵심:
#   "Nginx reload 기반 무중단 라우팅 롤백, 에러 0건"
# ============================================================

set -euo pipefail

# ── 설정 ──
NGINX_HOST="${NGINX_HOST:-localhost}"           # Nginx가 실행 중인 서버
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"

# Nginx 설정 경로
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx}"
UPSTREAM_CONF="${UPSTREAM_CONF:-${NGINX_CONF_DIR}/conf.d/upstream.conf}"
SITE_CONF="${SITE_CONF:-${NGINX_CONF_DIR}/sites-enabled/doktori.conf}"

# 서버 주소
OLD_BACKEND="${OLD_BACKEND:-<LIGHTSAIL_PRIVATE_IP>:8080}"      # 구 서버 (Lightsail)
NEW_BACKEND="${NEW_BACKEND:-<VPC_PRIVATE_IP>:8080}"            # 새 서버 (VPC)
OLD_CHAT="${OLD_CHAT:-<LIGHTSAIL_PRIVATE_IP>:8081}"
NEW_CHAT="${NEW_CHAT:-<VPC_PRIVATE_IP>:8081}"

# 헬스체크 URL
HEALTH_URL="${HEALTH_URL:-https://doktori.kr/api/health}"

LOG_DIR="/tmp/db-migration"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/nginx-rollback-$(date +%Y%m%d-%H%M%S).log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# SSH 실행 헬퍼
run_remote() {
    if [ "$NGINX_HOST" = "localhost" ]; then
        eval "$1"
    else
        ssh -i "$SSH_KEY" "${SSH_USER}@${NGINX_HOST}" "$1"
    fi
}

echo "========================================================"
echo " Nginx 라우팅 롤백 (→ 구 서버)"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
echo ""
echo "  Nginx 서버:  ${NGINX_HOST}"
echo "  롤백 방향:   새 VPC → 구 Lightsail"
echo ""

# ── 1. 현재 Nginx 설정 백업 ──
log "=== STEP 1: 현재 Nginx 설정 백업 ==="
BACKUP_SUFFIX="backup-$(date +%Y%m%d-%H%M%S)"

run_remote "sudo cp ${UPSTREAM_CONF} ${UPSTREAM_CONF}.${BACKUP_SUFFIX} 2>/dev/null" || true
run_remote "sudo cp ${SITE_CONF} ${SITE_CONF}.${BACKUP_SUFFIX} 2>/dev/null" || true
log "  ✅ 현재 설정 백업 완료 (.${BACKUP_SUFFIX})"
echo ""

# ── 2. 현재 upstream 확인 ──
log "=== STEP 2: 현재 upstream 설정 확인 ==="
CURRENT_UPSTREAM=$(run_remote "grep -A3 'upstream' ${UPSTREAM_CONF} 2>/dev/null || grep -A3 'upstream' ${SITE_CONF} 2>/dev/null" || echo "확인 불가")
log "  현재 upstream:"
echo "$CURRENT_UPSTREAM" | while read -r line; do
    log "    $line"
done
echo ""

echo "  롤백 대상:"
echo "    API upstream:  ${NEW_BACKEND} → ${OLD_BACKEND}"
echo "    Chat upstream: ${NEW_CHAT} → ${OLD_CHAT}"
echo ""
read -p "  Nginx 롤백을 진행하시겠습니까? (y/N): " CONFIRM
[ "$CONFIRM" != "y" ] && echo "취소됨." && exit 0

ROLLBACK_START=$(date +%s)

# ── 3. upstream 설정 롤백 ──
log "=== STEP 3: upstream 설정 롤백 ==="

# upstream.conf가 별도 파일인 경우
if run_remote "test -f ${UPSTREAM_CONF}" 2>/dev/null; then
    # 새 VPC IP → 구 Lightsail IP로 교체
    run_remote "sudo sed -i 's|${NEW_BACKEND}|${OLD_BACKEND}|g' ${UPSTREAM_CONF}"
    run_remote "sudo sed -i 's|${NEW_CHAT}|${OLD_CHAT}|g' ${UPSTREAM_CONF}"
    log "  ✅ ${UPSTREAM_CONF} 업데이트"
fi

# site config에 직접 proxy_pass가 있는 경우
if run_remote "grep -q '${NEW_BACKEND}' ${SITE_CONF} 2>/dev/null"; then
    run_remote "sudo sed -i 's|${NEW_BACKEND}|${OLD_BACKEND}|g' ${SITE_CONF}"
    run_remote "sudo sed -i 's|${NEW_CHAT}|${OLD_CHAT}|g' ${SITE_CONF}"
    log "  ✅ ${SITE_CONF} 업데이트"
fi

echo ""

# ── 4. Nginx 구문 검사 ──
log "=== STEP 4: Nginx 구문 검사 ==="
NGINX_TEST=$(run_remote "sudo nginx -t 2>&1")
echo "$NGINX_TEST"

if echo "$NGINX_TEST" | grep -q "syntax is ok"; then
    log "  ✅ Nginx 구문 검사 통과"
else
    log "  ❌ Nginx 구문 오류! 롤백 중단."
    log "  → 백업 파일에서 수동 복원: ${UPSTREAM_CONF}.${BACKUP_SUFFIX}"
    exit 1
fi
echo ""

# ── 5. Nginx reload ──
log "=== STEP 5: Nginx reload ==="
RELOAD_START=$(date +%s%3N)
run_remote "sudo nginx -s reload"
RELOAD_END=$(date +%s%3N)
RELOAD_MS=$((RELOAD_END - RELOAD_START))

log "  ✅ Nginx reload 완료 (${RELOAD_MS}ms)"
echo ""

# ── 6. 라우팅 확인 ──
log "=== STEP 6: 라우팅 정상 확인 (30초 모니터링) ==="
ERRORS=0
TOTAL=0

for i in $(seq 1 6); do
    sleep 5
    TOTAL=$((TOTAL + 1))
    STATUS=$(curl -s -o /dev/null -w '%{http_code}' "${HEALTH_URL}" 2>/dev/null || echo "000")

    if [ "$STATUS" = "200" ]; then
        log "  [${i}/6] ${HEALTH_URL} → ${STATUS} ✅"
    else
        ERRORS=$((ERRORS + 1))
        log "  [${i}/6] ${HEALTH_URL} → ${STATUS} ❌"
    fi
done
echo ""

# ── 7. 변경 후 upstream 확인 ──
log "=== STEP 7: 변경 후 upstream 확인 ==="
NEW_UPSTREAM=$(run_remote "grep -A3 'upstream' ${UPSTREAM_CONF} 2>/dev/null || grep -A3 'upstream' ${SITE_CONF} 2>/dev/null" || echo "확인 불가")
log "  변경 후 upstream:"
echo "$NEW_UPSTREAM" | while read -r line; do
    log "    $line"
done
echo ""

ROLLBACK_END=$(date +%s)
ROLLBACK_ELAPSED=$((ROLLBACK_END - ROLLBACK_START))

echo "========================================================"
echo " Nginx 롤백 완료"
echo "========================================================"
echo ""
echo "  롤백 소요 시간: ${ROLLBACK_ELAPSED}초"
echo "  Nginx reload:  ${RELOAD_MS}ms"
echo "  헬스체크 에러: ${ERRORS}/${TOTAL}"
echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "  ✅ Nginx 롤백 성공 — 에러 0건"
    echo ""
    echo "  포트폴리오 문장:"
    echo "  \"Nginx reload 기반 무중단 롤백, ${ROLLBACK_ELAPSED}초 내 완료, 에러 0건\""
else
    echo "  ⚠️ ${ERRORS}건 에러 발생 — 구 서버 상태 확인 필요"
    echo "  → 구 서버가 정상 실행 중인지 확인"
    echo "  → docker ps / systemctl status 확인"
fi
echo ""
echo "  백업 파일: ${UPSTREAM_CONF}.${BACKUP_SUFFIX}"
echo "  로그:      ${LOG_FILE}"
