#!/bin/bash
# ============================================================
# 06. DB 컷오버 리허설 (타임스탬프 자동 기록)
#
# 용도: Master(dev MySQL) → RDS 컷오버 전체 절차를 리허설
# 실행: dev 서버 + RDS 양쪽에 접속 가능한 환경에서
#
# 절차:
#   1. Seconds_Behind_Master = 0 확인
#   2. Master에 read_only = 1 (쓰기 차단)
#   3. 잔여 트랜잭션 동기화 확인 (binlog position 일치)
#   4. RDS 복제 중단 (승격)
#   5. 앱 DB 엔드포인트 전환
#   6. 쓰기 정상 확인
#
# 주의: 이 스크립트는 각 단계를 수동 확인 후 진행합니다 (자동 실행 아님)
# ============================================================

set -euo pipefail

# ── 설정 ──
MASTER_HOST="${MASTER_HOST:-localhost}"
MASTER_PORT="${MASTER_PORT:-3306}"
MASTER_USER="${MASTER_USER:-root}"
MASTER_PASS="${MASTER_PASS:-}"

RDS_HOST="${RDS_HOST:-<RDS_ENDPOINT>}"
RDS_PORT="${RDS_PORT:-3306}"
RDS_USER="${RDS_USER:-admin}"
RDS_PASS="${RDS_PASS:-}"

DB_NAME="${DB_NAME:-doktoridb}"
LOG_FILE="/tmp/db-migration/cutover-rehearsal-$(date +%Y%m%d-%H%M%S).log"

mkdir -p /tmp/db-migration

MASTER_CMD="mysql -h${MASTER_HOST} -P${MASTER_PORT} -u${MASTER_USER}"
RDS_CMD="mysql -h${RDS_HOST} -P${RDS_PORT} -u${RDS_USER}"
[ -n "$MASTER_PASS" ] && MASTER_CMD="$MASTER_CMD -p${MASTER_PASS}"
[ -n "$RDS_PASS" ] && RDS_CMD="$RDS_CMD -p${RDS_PASS}"

# ── 로그 함수 ──
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

wait_for_enter() {
    echo ""
    read -p "  ↵ Enter를 눌러 다음 단계로 진행... " _
    echo ""
}

record_time() {
    echo "$(date +%s)" > "/tmp/db-migration/cutover-$1.ts"
    log "  ⏱  $1 시각: $(date '+%H:%M:%S')"
}

echo "========================================"
echo " DB 컷오버 리허설"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo " 로그: ${LOG_FILE}"
echo "========================================"
echo ""
echo "  Master: ${MASTER_HOST}:${MASTER_PORT}"
echo "  Slave:  ${RDS_HOST}:${RDS_PORT}"
echo ""
echo "⚠️  이 스크립트는 각 단계마다 수동 확인 후 진행합니다."
echo "⚠️  k6 부하 테스트를 먼저 시작한 후 이 스크립트를 실행하세요."
echo ""
wait_for_enter

# ============================================================
# STEP 0: 사전 확인
# ============================================================
log "=== STEP 0: 사전 확인 ==="
record_time "start"

log "  복제 상태 확인..."
LAG=$($RDS_CMD -N -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master:" | awk '{print $2}')
IO=$($RDS_CMD -N -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_IO_Running:" | awk '{print $2}')
SQL=$($RDS_CMD -N -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_SQL_Running:" | awk '{print $2}')

log "  Slave_IO_Running: $IO"
log "  Slave_SQL_Running: $SQL"
log "  Seconds_Behind_Master: $LAG"

if [ "$IO" != "Yes" ] || [ "$SQL" != "Yes" ]; then
    log "  ❌ 복제가 정상 상태가 아닙니다. 중단합니다."
    exit 1
fi

if [ "$LAG" != "0" ]; then
    log "  ⚠️ Seconds_Behind_Master = $LAG (0이 아님)"
    log "  0이 될 때까지 대기하세요."
    read -p "  0이 되었으면 Enter: " _
fi

log "  ✅ 복제 상태 정상"
echo ""

# ============================================================
# STEP 1: Master를 read_only로 전환 (쓰기 차단 시작)
# ============================================================
log "=== STEP 1: Master read_only 전환 (⚠️ 쓰기 차단 시작) ==="
echo ""
echo "  이 순간부터 Master에 쓰기가 실패합니다."
echo "  k6 부하 테스트 로그에서 쓰기 에러를 관찰하세요."
echo ""
wait_for_enter

record_time "readonly_start"
$MASTER_CMD -e "SET GLOBAL read_only = 1;" 2>/dev/null
$MASTER_CMD -e "SET GLOBAL super_read_only = 1;" 2>/dev/null

log "  ✅ Master read_only = ON, super_read_only = ON"
log "  ⏱  쓰기 불가 구간 시작"
echo ""

# ============================================================
# STEP 2: 잔여 트랜잭션 동기화 확인
# ============================================================
log "=== STEP 2: 잔여 트랜잭션 동기화 확인 ==="

log "  Master binlog position:"
MASTER_STATUS=$($MASTER_CMD -e "SHOW MASTER STATUS\G" 2>/dev/null)
M_FILE=$(echo "$MASTER_STATUS" | grep "File:" | awk '{print $2}')
M_POS=$(echo "$MASTER_STATUS" | grep "Position:" | awk '{print $2}')
log "    File: $M_FILE, Position: $M_POS"

# Slave가 따라잡을 때까지 대기
log "  Slave 동기화 대기 중..."
for i in $(seq 1 30); do
    sleep 1
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
        log "  ⚠️ 30초 내 동기화 미완료. 계속 대기하시겠습니까?"
        wait_for_enter
    fi
done
echo ""

# ============================================================
# STEP 3: RDS 복제 중단 (승격)
# ============================================================
log "=== STEP 3: RDS 복제 중단 (Slave → 독립 Master로 승격) ==="
wait_for_enter

record_time "promotion"
$RDS_CMD -e "CALL mysql.rds_stop_replication;" 2>/dev/null

log "  ✅ 복제 중단 완료 — RDS가 독립 Master로 승격됨"
echo ""

# ============================================================
# STEP 4: RDS에 쓰기 가능 확인
# ============================================================
log "=== STEP 4: RDS 쓰기 가능 확인 ==="

RDS_READONLY=$($RDS_CMD -N -e "SELECT @@read_only;" 2>/dev/null)
log "  RDS read_only = $RDS_READONLY"

if [ "$RDS_READONLY" = "0" ]; then
    log "  ✅ RDS 쓰기 가능"
else
    log "  ❌ RDS가 아직 read_only 상태. 확인 필요."
fi
echo ""

# ============================================================
# STEP 5: Nginx stream 프록시 upstream 전환 (앱 재시작 불필요)
# ============================================================
log "=== STEP 5: DB 프록시 upstream 전환 (→ RDS) ==="
echo ""
echo "  사전 조건: 05.5-setup-db-proxy.sh로 프록시가 구성되어 있어야 합니다."
echo "  앱 DB_URL은 이미 127.0.0.1:3307을 바라보고 있어야 합니다."
echo ""

STREAM_CONF="${STREAM_CONF:-/etc/nginx/stream.d/db-proxy.conf}"

# 현재 upstream 확인
log "  현재 upstream:"
grep "server " "$STREAM_CONF" 2>/dev/null | head -1 || echo "  (확인 불가)"
echo ""

echo "  전환: 로컬 MySQL → RDS (${RDS_HOST}:${RDS_PORT})"
wait_for_enter

record_time "endpoint_switch_start"

# upstream을 RDS로 변경
sed -i "s|server .*:.*|server ${RDS_HOST}:${RDS_PORT};|" "$STREAM_CONF"
log "  upstream 변경 완료 → ${RDS_HOST}:${RDS_PORT}"

# nginx 설정 테스트 + reload
if nginx -t 2>&1; then
    systemctl reload nginx
    record_time "endpoint_switched"
    log "  ✅ nginx reload 완료 — 새 연결은 RDS로 전달됨"
else
    log "  ❌ nginx -t 실패! upstream 변경을 확인하세요."
    log "  복구: 수동으로 ${STREAM_CONF}을 수정 후 nginx reload"
    exit 1
fi

# ── HikariCP eviction 대기 + 프록시 경유 RDS 쓰기 검증 ──
echo ""
log "  HikariCP eviction 대기 중..."
log "  (read_only 실패 → 커넥션 evict → 새 커넥션 → nginx → RDS)"

VERIFY_MAX=20
VERIFY_OK=0
for i in $(seq 1 $VERIFY_MAX); do
    sleep 2
    # 프록시(3307) 경유 read_only 확인
    # - 로컬 MySQL로 라우팅 중 → @@read_only = 1
    # - RDS로 라우팅 완료    → @@read_only = 0
    READONLY_VAL=$(mysql -h127.0.0.1 -P"${PROXY_LISTEN_PORT:-3307}" \
                         -u"${RDS_USER}" ${RDS_PASS:+-p"${RDS_PASS}"} \
                         -N -e "SELECT @@read_only;" 2>/dev/null || echo "err")

    if [ "$READONLY_VAL" = "0" ]; then
        record_time "proxy_routed_to_rds"
        log "  ✅ [${i}/${VERIFY_MAX}] 프록시 → RDS 라우팅 확인 (@@read_only = 0)"
        VERIFY_OK=1
        break
    else
        log "  ⏳ [${i}/${VERIFY_MAX}] 대기 중... (@@read_only = ${READONLY_VAL}, HikariCP evict 진행)"
    fi
done

if [ "$VERIFY_OK" -eq 0 ]; then
    log "  ❌ ${VERIFY_MAX}회($(( VERIFY_MAX * 2 ))초) 내 RDS 라우팅 확인 실패"
    log "  확인 사항:"
    log "    1. nginx upstream: grep server ${STREAM_CONF}"
    log "    2. RDS read_only 직접 확인: mysql -h${RDS_HOST} -P${RDS_PORT} -u${RDS_USER} -e 'SELECT @@read_only;'"
    log "    3. 프록시 포트 리슨: ss -lntp | grep ${PROXY_LISTEN_PORT:-3307}"
    exit 1
fi
echo ""

# ============================================================
# STEP 6: 쓰기 정상 확인
# ============================================================
log "=== STEP 6: 쓰기 트래픽 정상 확인 ==="
echo ""
echo "  k6 부하 테스트에서 쓰기 에러가 더 이상 발생하지 않는지 확인하세요."
echo "  확인 후 Enter를 누르세요."
wait_for_enter

record_time "write_restored"
log "  ✅ 쓰기 트래픽 복구 확인"

# ============================================================
# 결과 요약
# ============================================================
echo ""
echo "========================================"
echo " 컷오버 리허설 결과"
echo "========================================"

# 시간 계산
T_START=$(cat /tmp/db-migration/cutover-start.ts 2>/dev/null || echo "0")
T_RO=$(cat /tmp/db-migration/cutover-readonly_start.ts 2>/dev/null || echo "0")
T_PROMO=$(cat /tmp/db-migration/cutover-promotion.ts 2>/dev/null || echo "0")
T_SWITCH=$(cat /tmp/db-migration/cutover-endpoint_switched.ts 2>/dev/null || echo "0")
T_WRITE=$(cat /tmp/db-migration/cutover-write_restored.ts 2>/dev/null || echo "0")

TOTAL=$((T_WRITE - T_RO))
WRITE_DOWN=$((T_WRITE - T_RO))
SYNC_TIME=$((T_PROMO - T_RO))

echo ""
echo "  | 항목                          | 값            |"
echo "  |-------------------------------|---------------|"
echo "  | 총 컷오버 소요 (read_only~복구)| ${TOTAL}초     |"
echo "  | 쓰기 불가 구간                 | ${WRITE_DOWN}초 |"
echo "  | 동기화 확인 시간               | ${SYNC_TIME}초  |"
echo ""
echo "  상세 로그: $LOG_FILE"
echo ""

if [ "$WRITE_DOWN" -le 60 ]; then
    echo "  ✅ 쓰기 불가 구간 60초 이내 — 성공 기준 달성"
else
    echo "  ⚠️ 쓰기 불가 구간 ${WRITE_DOWN}초 — 60초 초과, 절차 개선 필요"
fi

echo ""
echo "  다음 단계:"
echo "  - 이 리허설을 최소 2회 반복하세요"
echo "  - 2회 연속 성공하면 프로덕션 컷오버 진행 가능"
echo "  - 롤백 연습: ./07-cutover-rollback.sh"
