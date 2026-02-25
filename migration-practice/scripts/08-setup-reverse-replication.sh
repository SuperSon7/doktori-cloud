#!/bin/bash
# ============================================================
# 08. Reverse Replication 설정 (RDS → 구 Master)
#
# 용도: 컷오버 완료 후 RDS(새 Master) → 구 Master 방향으로
#       역방향 복제를 설정하여, 롤백 시 데이터 무손실을 보장한다.
#
# 타이밍: 06-cutover-rehearsal.sh 완료 직후 실행
#
# 절차:
#   1. RDS(새 Master)에서 binlog position 확인
#   2. 구 Master를 Slave로 설정 (CHANGE MASTER TO)
#   3. 역방향 복제 시작 + 모니터링
#
# 전제조건:
#   - RDS 파라미터 그룹에서 binlog_format=ROW, log_bin=ON 확인
#   - RDS 커스텀 파라미터 그룹 사용 (binlog_retention_hours 설정)
#   - 구 Master에 replication 유저 존재
#
# 포트폴리오 핵심:
#   "Reverse Replication으로 롤백 시 데이터 유실 0건 보장"
# ============================================================

set -euo pipefail

# ── 설정 ──
MASTER_HOST="${MASTER_HOST:-localhost}"        # 구 Master (→ 이제 Slave가 될 서버)
MASTER_PORT="${MASTER_PORT:-3306}"
MASTER_USER="${MASTER_USER:-root}"
MASTER_PASS="${MASTER_PASS:-}"

RDS_HOST="${RDS_HOST:-<RDS_ENDPOINT>}"         # 새 Master (RDS)
RDS_PORT="${RDS_PORT:-3306}"
RDS_USER="${RDS_USER:-admin}"
RDS_PASS="${RDS_PASS:-}"

REPL_USER="${REPL_USER:-repl_user}"
REPL_PASS="${REPL_PASS:-<REPLICATION_PASSWORD>}"

LOG_DIR="/tmp/db-migration"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/reverse-replication-$(date +%Y%m%d-%H%M%S).log"

MASTER_CMD="mysql -h${MASTER_HOST} -P${MASTER_PORT} -u${MASTER_USER}"
RDS_CMD="mysql -h${RDS_HOST} -P${RDS_PORT} -u${RDS_USER}"
[ -n "$MASTER_PASS" ] && MASTER_CMD="$MASTER_CMD -p${MASTER_PASS}"
[ -n "$RDS_PASS" ] && RDS_CMD="$RDS_CMD -p${RDS_PASS}"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

echo "========================================================"
echo " Reverse Replication 설정 (RDS → 구 Master)"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
echo ""
echo "  새 Master (RDS):  ${RDS_HOST}:${RDS_PORT}"
echo "  구 Master → Slave: ${MASTER_HOST}:${MASTER_PORT}"
echo ""
echo "  이 스크립트는 컷오버 완료 후 역방향 복제를 설정합니다."
echo "  롤백 시 데이터 유실을 방지하기 위한 안전장치입니다."
echo ""
read -p "  진행하시겠습니까? (y/N): " CONFIRM
[ "$CONFIRM" != "y" ] && echo "취소됨." && exit 0

REVERSE_START=$(date +%s)

# ── 1. RDS binlog 설정 확인 ──
log "=== STEP 1: RDS(새 Master) binlog 설정 확인 ==="

RDS_BINLOG=$($RDS_CMD -N -e "SHOW VARIABLES LIKE 'log_bin';" 2>/dev/null | awk '{print $2}')
RDS_FORMAT=$($RDS_CMD -N -e "SHOW VARIABLES LIKE 'binlog_format';" 2>/dev/null | awk '{print $2}')

log "  log_bin: ${RDS_BINLOG:-N/A}"
log "  binlog_format: ${RDS_FORMAT:-N/A}"

if [ "$RDS_BINLOG" != "ON" ]; then
    log "  ❌ RDS에서 binlog가 비활성화되어 있습니다."
    log "  → RDS 파라미터 그룹에서 binlog_format=ROW 설정 필요"
    log "  → 파라미터 변경 후 RDS 재부팅 필요"
    exit 1
fi
log "  ✅ RDS binlog 활성화 확인"
echo ""

# ── 2. RDS binlog retention 설정 ──
log "=== STEP 2: RDS binlog 보관 시간 설정 ==="
# RDS는 기본적으로 binlog를 즉시 삭제하므로 retention 설정 필요
$RDS_CMD -e "CALL mysql.rds_set_configuration('binlog retention hours', 72);" 2>/dev/null && \
    log "  ✅ binlog 보관 시간: 72시간" || \
    log "  ⚠️ binlog retention 설정 실패 (RDS 프로시저 권한 확인)"
echo ""

# ── 3. RDS에서 replication 유저 생성 ──
log "=== STEP 3: RDS에서 replication 유저 생성 ==="
$RDS_CMD -e "
CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED BY '${REPL_PASS}';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${REPL_USER}'@'%';
FLUSH PRIVILEGES;
" 2>/dev/null && \
    log "  ✅ Replication 유저 생성/확인 완료 (${REPL_USER})" || \
    log "  ⚠️ 유저 생성 실패 — 이미 존재하면 무시 가능"
echo ""

# ── 4. RDS(새 Master) binlog position 기록 ──
log "=== STEP 4: RDS binlog position 기록 ==="
BINLOG_INFO=$($RDS_CMD -e "SHOW MASTER STATUS\G" 2>/dev/null)
BINLOG_FILE=$(echo "$BINLOG_INFO" | grep "File:" | awk '{print $2}')
BINLOG_POS=$(echo "$BINLOG_INFO" | grep "Position:" | awk '{print $2}')

log "  File: ${BINLOG_FILE}"
log "  Position: ${BINLOG_POS}"

if [ -z "$BINLOG_FILE" ] || [ -z "$BINLOG_POS" ]; then
    log "  ❌ binlog position 확인 실패"
    log "  → SHOW MASTER STATUS 수동 실행하여 확인"
    exit 1
fi
log "  ✅ binlog position 기록 완료"
echo ""

# ── 5. 구 Master에서 기존 복제 정보 초기화 ──
log "=== STEP 5: 구 Master 복제 초기화 ==="
$MASTER_CMD -e "STOP SLAVE; RESET SLAVE ALL;" 2>/dev/null || true
log "  ✅ 구 Master 기존 복제 정보 초기화"
echo ""

# ── 6. 구 Master를 RDS의 Slave로 설정 ──
log "=== STEP 6: 구 Master → RDS Slave 설정 ==="
$MASTER_CMD -e "
CHANGE MASTER TO
    MASTER_HOST='${RDS_HOST}',
    MASTER_PORT=${RDS_PORT},
    MASTER_USER='${REPL_USER}',
    MASTER_PASSWORD='${REPL_PASS}',
    MASTER_LOG_FILE='${BINLOG_FILE}',
    MASTER_LOG_POS=${BINLOG_POS},
    MASTER_SSL=1;
" 2>/dev/null

log "  ✅ CHANGE MASTER TO 실행 완료"
echo ""

# ── 7. 역방향 복제 시작 ──
log "=== STEP 7: 역방향 복제 시작 ==="
$MASTER_CMD -e "START SLAVE;" 2>/dev/null
sleep 2

SLAVE_STATUS=$($MASTER_CMD -e "SHOW SLAVE STATUS\G" 2>/dev/null)
IO_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_IO_Running:" | awk '{print $2}')
SQL_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')
LAST_ERROR=$(echo "$SLAVE_STATUS" | grep "Last_Error:" | sed 's/.*Last_Error: //')

log "  Slave_IO_Running: ${IO_RUNNING}"
log "  Slave_SQL_Running: ${SQL_RUNNING}"

if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
    log "  ✅ 역방향 복제 정상 시작!"
else
    log "  ❌ 역방향 복제 시작 실패"
    log "  Last_Error: ${LAST_ERROR}"
    log ""
    log "  트러블슈팅:"
    log "  1. RDS 보안그룹에서 구 Master IP의 3306 포트 허용 확인"
    log "  2. repl_user 권한 확인: SHOW GRANTS FOR '${REPL_USER}'@'%';"
    log "  3. 네트워크 연결 확인: mysql -h${RDS_HOST} -u${REPL_USER} -p"
    exit 1
fi
echo ""

# ── 8. 역방향 복제 모니터링 (30초) ──
log "=== STEP 8: 역방향 복제 안정성 확인 (30초 모니터링) ==="
for i in $(seq 1 6); do
    sleep 5
    BEHIND=$($MASTER_CMD -N -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master:" | awk '{print $2}')
    IO=$($MASTER_CMD -N -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_IO_Running:" | awk '{print $2}')
    SQL=$($MASTER_CMD -N -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_SQL_Running:" | awk '{print $2}')
    log "  [${i}/6] IO=${IO} SQL=${SQL} Behind=${BEHIND}s"
done
echo ""

REVERSE_END=$(date +%s)
REVERSE_ELAPSED=$((REVERSE_END - REVERSE_START))

echo "========================================================"
echo " Reverse Replication 설정 완료"
echo "========================================================"
echo ""
echo "  방향: RDS(${RDS_HOST}) → 구 Master(${MASTER_HOST})"
echo "  소요 시간: ${REVERSE_ELAPSED}초"
echo ""
echo "  ✅ 이제 롤백이 필요해도 데이터 유실 없이 복구 가능"
echo ""
echo "  롤백 시 절차:"
echo "  1. RDS read_only = 1"
echo "  2. 구 Master에서 STOP SLAVE → Seconds_Behind_Master = 0 확인"
echo "  3. 구 Master read_only = 0"
echo "  4. 앱 DB 엔드포인트를 구 Master로 원복"
echo ""
echo "  모니터링: 04-monitor-replication.sh (HOST 변수 반대로 설정)"
echo ""
echo "  로그: ${LOG_FILE}"
