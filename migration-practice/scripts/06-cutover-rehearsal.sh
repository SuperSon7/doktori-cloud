#!/bin/bash
# ============================================================
# 06. DB 컷오버 리허설 v2 (reload + KILL 방식)
#
# 개선 포인트 (vs v1):
#   - nginx reload를 먼저 실행 → 새 커넥션 경로를 사전 배치
#   - nginx restart 대신 reload → DB 외 트래픽 영향 0
#   - KILL CONNECTION으로 앱 DB 커넥션만 선택적 해제
#   - 다운타임: 전체 서비스 1-2초 → DB 재연결 수십ms
#
# 절차:
#   0. 사전 확인 (복제 상태)
#   1. nginx upstream → RDS + reload (새 커넥션 경로 사전 배치)
#   2. Master super_read_only (쓰기 차단)
#   3. 잔여 트랜잭션 동기화 확인
#   4. RDS 복제 중단 (승격)
#   5. 구 Master 앱 커넥션 KILL → HikariCP 재연결 → RDS
#   6. 쓰기 정상 확인
#
# --auto 플래그: 크리티컬 경로의 Enter 대기를 건너뜀
# ============================================================

set -euo pipefail

# ── --auto 모드 ──
AUTO_MODE=false
if [[ "${1:-}" == "--auto" ]]; then
    AUTO_MODE=true
fi

# ── 설정 ──
MASTER_HOST="${MASTER_HOST:-localhost}"
MASTER_PORT="${MASTER_PORT:-3306}"
MASTER_USER="${MASTER_USER:-doktori_prod}"
MASTER_PASS="${MASTER_PASS:-hJoz3NCsL2ubKvJrYRsb}"

RDS_HOST="${RDS_HOST:-doktoritest.cvqsyou66939.ap-northeast-2.rds.amazonaws.com}"
RDS_PORT="${RDS_PORT:-3306}"
RDS_USER="${RDS_USER:-doktori_prod}"
RDS_PASS="${RDS_PASS:-hJoz3NCsL2ubKvJrYRsb}"

DB_NAME="${DB_NAME:-doktoridb}"
PROXY_LISTEN_PORT="${PROXY_LISTEN_PORT:-3307}"
STREAM_CONF="${STREAM_CONF:-/etc/nginx/stream.d/db-proxy.conf}"
LOG_FILE="/tmp/db-migration/cutover-rehearsal-$(date +%Y%m%d-%H%M%S).log"

mkdir -p /tmp/db-migration

MASTER_CMD="mysql -h${MASTER_HOST} -P${MASTER_PORT} -u${MASTER_USER}"
RDS_CMD="mysql -h${RDS_HOST} -P${RDS_PORT} -u${RDS_USER}"
PROXY_CMD="mysql -h127.0.0.1 -P${PROXY_LISTEN_PORT} -u${RDS_USER}"
[ -n "$MASTER_PASS" ] && MASTER_CMD="$MASTER_CMD -p${MASTER_PASS}"
[ -n "$RDS_PASS" ] && RDS_CMD="$RDS_CMD -p${RDS_PASS}"
[ -n "$RDS_PASS" ] && PROXY_CMD="$PROXY_CMD -p${RDS_PASS}"

# ── 로그 함수 ──
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

wait_for_enter() {
    if [ "$AUTO_MODE" = true ]; then
        echo ""
        return
    fi
    echo ""
    read -p "  ↵ Enter를 눌러 다음 단계로 진행... " _
    echo ""
}

record_time() {
    echo "$(date +%s)" > "/tmp/db-migration/cutover-$1.ts"
    log "  ⏱  $1 시각: $(date '+%H:%M:%S')"
}

echo "========================================"
echo " DB 컷오버 리허설 v2 (reload + KILL)"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo " 로그: ${LOG_FILE}"
echo "========================================"
echo ""
echo "  Master: ${MASTER_HOST}:${MASTER_PORT}"
echo "  Slave:  ${RDS_HOST}:${RDS_PORT}"
echo "  Proxy:  127.0.0.1:${PROXY_LISTEN_PORT}"
echo ""
if [ "$AUTO_MODE" = true ]; then
    echo "  AUTO 모드: 크리티컬 경로의 Enter 대기를 건너뜁니다."
else
    echo "  각 단계마다 수동 확인 후 진행합니다."
fi
echo "  k6 부하 테스트를 먼저 시작한 후 이 스크립트를 실행하세요."
echo ""
wait_for_enter

# ============================================================
# STEP 0: 사전 확인
# ============================================================
log "=== STEP 0: 사전 확인 ==="
record_time "start"

log "  복제 상태 확인..."
LAG=$($RDS_CMD -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master:" | awk '{print $2}')
IO=$($RDS_CMD -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_IO_Running:" | awk '{print $2}')
SQL=$($RDS_CMD -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_SQL_Running:" | awk '{print $2}')

log "  Slave_IO_Running: $IO"
log "  Slave_SQL_Running: $SQL"
log "  Seconds_Behind_Master: $LAG"

if [ "$IO" != "Yes" ] || [ "$SQL" != "Yes" ]; then
    log "  ❌ 복제가 정상 상태가 아닙니다. 중단합니다."
    exit 1
fi

if [ "$LAG" != "0" ]; then
    log "  ⚠️ Seconds_Behind_Master = $LAG (0이 아님)"
    log "  0이 될 때까지 자동 대기 중... (5초 간격)"
    while true; do
        sleep 5
        LAG=$($RDS_CMD -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master:" | awk '{print $2}')
        printf "\r  Seconds_Behind_Master: %-10s" "$LAG"
        if [ "$LAG" = "0" ]; then
            echo ""
            break
        fi
    done
fi

log "  ✅ 복제 상태 정상"
echo ""

# ============================================================
# STEP 1: nginx upstream → RDS + reload (경로 사전 배치)
#
# reload는 기존 커넥션을 끊지 않음
# 새로 맺히는 커넥션만 RDS로 향하게 '길을 깔아두는 것'
# ============================================================
log "=== STEP 1: nginx upstream → RDS 사전 전환 ==="
echo ""
echo "  reload → 기존 커넥션 유지, 새 커넥션만 RDS로"
echo ""

log "  현재 upstream:"
grep "server " "$STREAM_CONF" 2>/dev/null | head -1 || echo "  (확인 불가)"

echo "  전환: → RDS (${RDS_HOST}:${RDS_PORT})"
wait_for_enter

record_time "nginx_reload_start"

sudo sed -i "s|server .*:.*|server ${RDS_HOST}:${RDS_PORT};|" "$STREAM_CONF"
log "  upstream 변경 → ${RDS_HOST}:${RDS_PORT}"

if sudo nginx -t 2>&1; then
    sudo systemctl reload nginx
    record_time "nginx_reloaded"
    log "  ✅ nginx reload 완료 — 새 커넥션은 RDS로 전달"
    log "     기존 앱 커넥션은 아직 구 Master 연결 유지 중"
else
    log "  ❌ nginx -t 실패! upstream을 확인하세요."
    exit 1
fi
echo ""

# ============================================================
# STEP 2: Master super_read_only (쓰기 차단 시작)
# ============================================================
log "=== STEP 2: Master super_read_only (⚠️ 쓰기 차단 시작) ==="
echo ""
echo "  이 순간부터 구 Master에 쓰기가 실패합니다."
echo ""
wait_for_enter

record_time "readonly_start"
$MASTER_CMD -e "SET GLOBAL read_only = 1;" 2>/dev/null
$MASTER_CMD -e "SET GLOBAL super_read_only = 1;" 2>/dev/null

log "  ✅ read_only = ON, super_read_only = ON"
log "  ⏱  쓰기 불가 구간 시작"
echo ""

# ============================================================
# STEP 3: 잔여 트랜잭션 동기화 확인
# ============================================================
log "=== STEP 3: 잔여 트랜잭션 동기화 확인 ==="

MASTER_STATUS=$($MASTER_CMD -e "SHOW MASTER STATUS\G" 2>/dev/null)
M_FILE=$(echo "$MASTER_STATUS" | grep "File:" | awk '{print $2}')
M_POS=$(echo "$MASTER_STATUS" | grep "Position:" | awk '{print $2}')
log "  Master: File=$M_FILE, Pos=$M_POS"

log "  Slave 동기화 대기 중..."
for i in $(seq 1 30); do
    SLAVE_STATUS=$($RDS_CMD -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    S_FILE=$(echo "$SLAVE_STATUS" | grep "Relay_Master_Log_File:" | awk '{print $2}')
    S_POS=$(echo "$SLAVE_STATUS" | grep "Exec_Master_Log_Pos:" | awk '{print $2}')
    S_LAG=$(echo "$SLAVE_STATUS" | grep "Seconds_Behind_Master:" | awk '{print $2}')

    log "    [${i}/30] Slave: File=$S_FILE, Pos=$S_POS, Lag=$S_LAG"

    if [ "$S_FILE" = "$M_FILE" ] && [ "$S_POS" = "$M_POS" ]; then
        log "  ✅ binlog position 일치 — 동기화 완료"
        break
    fi

    if [ "$i" -eq 30 ]; then
        log "  ⚠️ 30초 내 동기화 미완료"
        wait_for_enter
    fi
    sleep 1
done
echo ""

# ============================================================
# STEP 4: RDS 복제 중단 (승격)
# ============================================================
log "=== STEP 4: RDS 승격 (rds_stop_replication) ==="
wait_for_enter

record_time "promotion"
$RDS_CMD -e "CALL mysql.rds_stop_replication;" 2>/dev/null

log "  ✅ RDS 독립 Master로 승격"

RDS_READONLY=$($RDS_CMD -N -e "SELECT @@read_only;" 2>/dev/null)
log "  RDS read_only = $RDS_READONLY"

if [ "$RDS_READONLY" = "0" ]; then
    log "  ✅ RDS 쓰기 가능"
else
    log "  ❌ RDS가 아직 read_only. 수동 확인 필요."
    exit 1
fi
echo ""

# ============================================================
# STEP 5: 구 Master 앱 커넥션 KILL → HikariCP 자동 재연결
#
# 구 Master에서 앱 세션을 끊으면:
#   MySQL이 TCP 닫음 → nginx가 감지 → 프론트엔드 커넥션도 닫음
#   → HikariCP가 dead connection 폐기 → 새 커넥션 생성
#   → 새 커넥션은 STEP 1에서 reload한 nginx를 타고 RDS로 연결
# ============================================================
log "=== STEP 5: 구 Master 앱 커넥션 KILL ==="

record_time "kill_connections"

CONN_IDS=$($MASTER_CMD -N -e "SELECT id FROM information_schema.processlist WHERE user = '${MASTER_USER}';" 2>/dev/null)
KILL_COUNT=0
for CID in $CONN_IDS; do
    $MASTER_CMD -e "KILL CONNECTION $CID;" 2>/dev/null || true
    KILL_COUNT=$((KILL_COUNT + 1))
done

log "  ✅ ${KILL_COUNT}개 커넥션 KILL 완료"

# 프록시 경유 RDS 라우팅 검증
log "  프록시 → RDS 라우팅 확인 중..."
VERIFY_MAX=10
VERIFY_OK=0
for i in $(seq 1 $VERIFY_MAX); do
    READONLY_VAL=$($PROXY_CMD -N -e "SELECT @@read_only;" 2>/dev/null || echo "err")
    if [ "$READONLY_VAL" = "0" ]; then
        record_time "proxy_routed_to_rds"
        log "  ✅ [${i}/${VERIFY_MAX}] 프록시 → RDS 확인 (@@read_only = 0)"
        VERIFY_OK=1
        break
    else
        log "  ⏳ [${i}/${VERIFY_MAX}] 대기 중... (@@read_only = ${READONLY_VAL})"
    fi
    sleep 1
done

if [ "$VERIFY_OK" -eq 0 ]; then
    log "  ❌ 프록시 → RDS 라우팅 확인 실패"
    exit 1
fi

record_time "write_restored"
log "  ⏱  쓰기 불가 구간 종료"
echo ""

# ============================================================
# STEP 6: 쓰기 정상 확인 + 후처리
# ============================================================
log "=== STEP 6: 쓰기 확인 + 후처리 ==="
if [ "$AUTO_MODE" = true ]; then
    log "  ✅ 쓰기 트래픽 복구 (auto)"
else
    echo ""
    echo "  k6에서 쓰기 에러가 멈췄는지 확인 후 Enter"
    wait_for_enter
    log "  ✅ 쓰기 트래픽 복구 확인"
fi

# AI 서버 재시작 (크리티컬 패스 밖)
log "  AI 서버 재시작..."
sudo systemctl restart doktori-ai-green 2>/dev/null || true
AI_STATUS=$(systemctl is-active doktori-ai-green 2>/dev/null || echo "unknown")
if [ "$AI_STATUS" = "active" ]; then
    log "  ✅ AI 서버 재시작 완료"
else
    log "  ⚠️ AI 서버: $AI_STATUS — 수동 확인 필요"
fi

# ============================================================
# 결과 요약
# ============================================================
echo ""
echo "========================================"
echo " 컷오버 리허설 결과"
echo "========================================"

T_RO=$(cat /tmp/db-migration/cutover-readonly_start.ts 2>/dev/null || echo "0")
T_PROMO=$(cat /tmp/db-migration/cutover-promotion.ts 2>/dev/null || echo "0")
T_KILL=$(cat /tmp/db-migration/cutover-kill_connections.ts 2>/dev/null || echo "0")
T_WRITE=$(cat /tmp/db-migration/cutover-write_restored.ts 2>/dev/null || echo "0")

WRITE_DOWN=$((T_WRITE - T_RO))
SYNC_TIME=$((T_PROMO - T_RO))
KILL_TO_RESTORE=$((T_WRITE - T_KILL))

echo ""
echo "  | 항목                           | 값          |"
echo "  |--------------------------------|-------------|"
echo "  | 쓰기 불가 구간 (read_only~복구) | ${WRITE_DOWN}초     |"
echo "  | 동기화 확인                      | ${SYNC_TIME}초     |"
echo "  | KILL → 쓰기 복구                | ${KILL_TO_RESTORE}초     |"
echo ""
echo "  상세 로그: $LOG_FILE"
echo ""

if [ "$WRITE_DOWN" -le 60 ]; then
    echo "  ✅ 쓰기 불가 구간 ${WRITE_DOWN}초 — 성공 기준 달성"
else
    echo "  ⚠️ 쓰기 불가 구간 ${WRITE_DOWN}초 — 60초 초과"
fi

echo ""
echo "  다음 단계:"
echo "  - 리허설을 최소 2회 반복"
echo "  - 롤백 연습: ./07-cutover-rollback.sh"