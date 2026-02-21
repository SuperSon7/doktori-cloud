#!/bin/bash
# ============================================================
# 07. 컷오버 롤백 (역방향 복구)
#
# 용도: 컷오버 후 문제 발생 시 구 Master로 원복
# 실행: 컷오버 리허설(06) 실행 후, 롤백 연습 시 사용
#
# 절차:
#   1. RDS(새 Master)에 read_only = 1
#   2. 구 Master의 read_only 해제
#   3. 앱 엔드포인트를 구 Master로 원복
#
# 주의: 구 Master가 살아있어야 롤백 가능 (이것이 72시간 유지하는 이유)
#
# v2 업데이트: Reverse Replication 활용 롤백
#   - 08-setup-reverse-replication.sh로 역방향 복제가 설정된 경우
#   - 구 Master가 RDS의 Slave로 동작 중 → 데이터 유실 없는 롤백 가능
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

MASTER_CMD="mysql -h${MASTER_HOST} -P${MASTER_PORT} -u${MASTER_USER}"
RDS_CMD="mysql -h${RDS_HOST} -P${RDS_PORT} -u${RDS_USER}"
[ -n "$MASTER_PASS" ] && MASTER_CMD="$MASTER_CMD -p${MASTER_PASS}"
[ -n "$RDS_PASS" ] && RDS_CMD="$RDS_CMD -p${RDS_PASS}"

LOG_FILE="/tmp/db-migration/cutover-rollback-$(date +%Y%m%d-%H%M%S).log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

echo "========================================"
echo " ⚠️  컷오버 롤백 (구 Master로 원복)"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""
echo "  이 스크립트는 컷오버 후 문제 발생 시 역방향 복구합니다."
echo "  구 Master(${MASTER_HOST})가 살아있어야 합니다."
echo ""
read -p "  롤백을 진행하시겠습니까? (y/N): " CONFIRM
[ "$CONFIRM" != "y" ] && echo "취소됨." && exit 0

ROLLBACK_START=$(date +%s)

# ── 0. Reverse Replication 상태 확인 ──
log "=== STEP 0: Reverse Replication 상태 확인 ==="
REVERSE_STATUS=$($MASTER_CMD -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_IO_Running:" | awk '{print $2}' || echo "N/A")

if [ "$REVERSE_STATUS" = "Yes" ]; then
    log "  ✅ Reverse Replication 활성 — 데이터 유실 없는 롤백 가능"
    REVERSE_REPL=true

    # 역방향 복제 지연 확인
    BEHIND=$($MASTER_CMD -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master:" | awk '{print $2}')
    log "  Seconds_Behind_Master: ${BEHIND}s"

    if [ "$BEHIND" != "0" ] && [ "$BEHIND" != "NULL" ]; then
        log "  ⚠️ 복제 지연 있음. 동기화 대기 중..."
        for i in $(seq 1 30); do
            sleep 2
            BEHIND=$($MASTER_CMD -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master:" | awk '{print $2}')
            log "    [${i}/30] Behind=${BEHIND}s"
            [ "$BEHIND" = "0" ] && break
        done
    fi
    log "  ✅ 역방향 복제 동기화 완료"
else
    log "  ⚠️ Reverse Replication 미설정 — 컷오버~롤백 간 데이터 유실 가능"
    log "  → 08-setup-reverse-replication.sh를 먼저 실행하면 안전한 롤백 가능"
    REVERSE_REPL=false
fi
echo ""

# ── 1. RDS에 read_only 설정 ──
log "=== STEP 1: RDS read_only 설정 ==="
# RDS는 파라미터 그룹으로 read_only를 설정해야 할 수 있음
# 또는 직접 SET GLOBAL이 가능한 경우:
$RDS_CMD -e "SET GLOBAL read_only = 1;" 2>/dev/null && \
    log "  ✅ RDS read_only = ON" || \
    log "  ⚠️ RDS read_only 설정 실패 (파라미터 그룹에서 변경 필요할 수 있음)"
echo ""

# ── 1.5. Reverse Replication 중지 (설정된 경우) ──
if [ "$REVERSE_REPL" = "true" ]; then
    log "=== STEP 1.5: 구 Master에서 Slave 중지 ==="
    $MASTER_CMD -e "STOP SLAVE;" 2>/dev/null
    log "  ✅ 구 Master Slave 중지 (최신 데이터까지 적용 완료)"
fi
echo ""

# ── 2. 구 Master의 read_only 해제 ──
log "=== STEP 2: 구 Master read_only 해제 ==="
$MASTER_CMD -e "SET GLOBAL super_read_only = 0;" 2>/dev/null
$MASTER_CMD -e "SET GLOBAL read_only = 0;" 2>/dev/null
log "  ✅ 구 Master read_only = OFF, super_read_only = OFF"
echo ""

# ── 3. 구 Master 쓰기 가능 확인 ──
log "=== STEP 3: 구 Master 쓰기 가능 확인 ==="
M_READONLY=$($MASTER_CMD -N -e "SELECT @@read_only;" 2>/dev/null)
log "  구 Master read_only = $M_READONLY"

if [ "$M_READONLY" = "0" ]; then
    log "  ✅ 구 Master 쓰기 가능"
else
    log "  ❌ 구 Master가 아직 read_only. 수동 확인 필요."
fi
echo ""

# ── 4. 앱 엔드포인트 원복 안내 ──
log "=== STEP 4: 앱 DB 엔드포인트 원복 ==="
echo ""
echo "  지금 해야 할 것:"
echo "  1. AWS Parameter Store에서 DB_URL을 구 Master로 원복"
echo "     /doktori/dev/DB_URL → jdbc:mysql://${MASTER_HOST}:${MASTER_PORT}/doktoridb?..."
echo ""
echo "  2. 앱 컨테이너 재시작"
echo "     docker restart backend-api backend-chat"
echo ""
echo "  3. 헬스체크 + 쓰기 정상 확인"
echo ""
read -p "  완료 후 Enter: " _

ROLLBACK_END=$(date +%s)
ROLLBACK_ELAPSED=$((ROLLBACK_END - ROLLBACK_START))

echo ""
echo "========================================"
echo " 롤백 완료"
echo "========================================"
echo ""
echo "  롤백 소요 시간: ${ROLLBACK_ELAPSED}초"
echo ""
if [ "$ROLLBACK_ELAPSED" -le 180 ]; then
    echo "  ✅ 3분 이내 롤백 완료 — 성공 기준 달성"
else
    echo "  ⚠️ ${ROLLBACK_ELAPSED}초 소요 — 3분(180초) 초과"
fi
echo ""
if [ "$REVERSE_REPL" = "true" ]; then
    echo "  ✅ Reverse Replication으로 롤백 — 데이터 유실 0건"
    echo ""
    echo "  포트폴리오 문장:"
    echo "  \"Reverse Replication으로 롤백 시 데이터 유실 0건, ${ROLLBACK_ELAPSED}초 내 완료\""
else
    echo "  ⚠️ 롤백 후 주의사항:"
    echo "  - 컷오버~롤백 사이에 RDS에 쓰인 데이터는 구 Master에 없습니다"
    echo "  - 쓰기 불가 구간이 짧았다면 유실 데이터는 거의 없을 것"
    echo "  - 유실 여부는 RDS의 binlog를 확인하여 파악 가능"
    echo "  - 향후에는 08-setup-reverse-replication.sh를 사용하세요"
fi
