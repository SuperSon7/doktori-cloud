#!/bin/bash
# ============================================================
# 09. CHECKSUM 기반 데이터 정합성 검증
#
# 용도: CHECKSUM TABLE로 Master ↔ Slave 바이트 수준 정합성 검증
#       Row count만으로는 잡을 수 없는 데이터 변조/누락을 감지한다.
#
# 실행 타이밍:
#   - 복제 완료 후 (Seconds_Behind_Master = 0)
#   - 컷오버 직전 최종 검증
#   - 컷오버 직후 역방향 복제 안정화 확인
#
# 포트폴리오 핵심:
#   "CHECKSUM TABLE로 전 테이블 바이트 수준 정합성 100% 확인"
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

LOG_DIR="/tmp/db-migration"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/checksum-$(date +%Y%m%d-%H%M%S).log"
CSV_FILE="${LOG_DIR}/checksum-$(date +%Y%m%d-%H%M%S).csv"

MASTER_CMD="mysql -h${MASTER_HOST} -P${MASTER_PORT} -u${MASTER_USER} -N"
RDS_CMD="mysql -h${RDS_HOST} -P${RDS_PORT} -u${RDS_USER} -N"
[ -n "$MASTER_PASS" ] && MASTER_CMD="$MASTER_CMD -p${MASTER_PASS}"
[ -n "$RDS_PASS" ] && RDS_CMD="$RDS_CMD -p${RDS_PASS}"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

echo "========================================================"
echo " CHECKSUM 기반 데이터 정합성 검증"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
echo ""
echo "  Master: ${MASTER_HOST}:${MASTER_PORT}"
echo "  Slave:  ${RDS_HOST}:${RDS_PORT}"
echo "  DB:     ${DB_NAME}"
echo ""

# ── 0. 복제 지연 확인 ──
log "=== 사전 확인: 복제 지연 체크 ==="
BEHIND=$($RDS_CMD -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master:" | awk '{print $2}' || echo "N/A")

if [ "$BEHIND" != "0" ] && [ "$BEHIND" != "N/A" ] && [ "$BEHIND" != "NULL" ]; then
    log "  ⚠️ Seconds_Behind_Master = ${BEHIND}초"
    log "  → 복제 지연이 있으면 CHECKSUM이 불일치할 수 있습니다."
    read -p "  계속하시겠습니까? (y/N): " CONT
    [ "$CONT" != "y" ] && echo "취소됨." && exit 0
else
    log "  ✅ 복제 동기화 완료 (Behind=${BEHIND})"
fi
echo ""

# ── 1. 테이블 목록 조회 ──
log "=== STEP 1: 테이블 목록 조회 ==="
TABLES=$($MASTER_CMD -e "
SELECT TABLE_NAME
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='${DB_NAME}'
  AND TABLE_TYPE='BASE TABLE'
ORDER BY TABLE_NAME;
" 2>/dev/null)

TABLE_COUNT=$(echo "$TABLES" | grep -c . || echo "0")
log "  총 ${TABLE_COUNT}개 테이블 발견"
echo ""

# ── 2. CHECKSUM TABLE 비교 ──
log "=== STEP 2: CHECKSUM TABLE 비교 ==="
echo ""
printf "  %-40s | %15s | %15s | %10s | %s\n" "테이블" "Master CRC" "Slave CRC" "Row Count" "상태"
echo "  ----------------------------------------+----------------+-----------------+------------+--------"

# CSV 헤더
echo "table,master_checksum,slave_checksum,master_rows,slave_rows,match" > "$CSV_FILE"

MISMATCH=0
CHECKED=0
TOTAL_MASTER_ROWS=0
TOTAL_SLAVE_ROWS=0

while IFS= read -r TABLE; do
    [ -z "$TABLE" ] && continue
    CHECKED=$((CHECKED + 1))

    # Master CHECKSUM
    M_RESULT=$($MASTER_CMD -e "CHECKSUM TABLE ${DB_NAME}.${TABLE};" 2>/dev/null)
    M_CHECKSUM=$(echo "$M_RESULT" | awk '{print $2}')

    # Slave CHECKSUM
    S_RESULT=$($RDS_CMD -e "CHECKSUM TABLE ${DB_NAME}.${TABLE};" 2>/dev/null)
    S_CHECKSUM=$(echo "$S_RESULT" | awk '{print $2}')

    # Row count (검증 보조)
    M_ROWS=$($MASTER_CMD -e "SELECT COUNT(*) FROM ${DB_NAME}.${TABLE};" 2>/dev/null | tr -d '[:space:]')
    S_ROWS=$($RDS_CMD -e "SELECT COUNT(*) FROM ${DB_NAME}.${TABLE};" 2>/dev/null | tr -d '[:space:]')
    TOTAL_MASTER_ROWS=$((TOTAL_MASTER_ROWS + M_ROWS))
    TOTAL_SLAVE_ROWS=$((TOTAL_SLAVE_ROWS + S_ROWS))

    if [ "$M_CHECKSUM" = "$S_CHECKSUM" ]; then
        STATUS="✅"
        MATCH="true"
    else
        STATUS="❌"
        MATCH="false"
        MISMATCH=$((MISMATCH + 1))
        log "  ❌ MISMATCH: ${TABLE} (Master=${M_CHECKSUM}, Slave=${S_CHECKSUM}, Rows: M=${M_ROWS}/S=${S_ROWS})"
    fi

    printf "  %-40s | %15s | %15s | %10s | %s\n" "$TABLE" "$M_CHECKSUM" "$S_CHECKSUM" "${M_ROWS}/${S_ROWS}" "$STATUS"

    # CSV 기록
    echo "${TABLE},${M_CHECKSUM},${S_CHECKSUM},${M_ROWS},${S_ROWS},${MATCH}" >> "$CSV_FILE"

done <<< "$TABLES"

echo ""
echo ""

# ── 3. 결과 요약 ──
echo "========================================================"
echo " CHECKSUM 검증 결과"
echo "========================================================"
echo ""
echo "  검증 테이블: ${CHECKED}개"
echo "  일치:       $((CHECKED - MISMATCH))개"
echo "  불일치:     ${MISMATCH}개"
echo "  총 Row수:   Master=${TOTAL_MASTER_ROWS} / Slave=${TOTAL_SLAVE_ROWS}"
echo ""

if [ "$MISMATCH" -eq 0 ]; then
    log "  ✅ 전체 CHECKSUM 일치 — 바이트 수준 데이터 정합성 확인!"
    echo ""
    echo "  포트폴리오 문장:"
    echo "  \"${CHECKED}개 테이블, ${TOTAL_MASTER_ROWS} rows CHECKSUM 100% 일치 확인\""
    echo ""
    echo "  → 컷오버 진행 가능 (06-cutover-rehearsal.sh)"
else
    log "  ❌ ${MISMATCH}개 테이블 CHECKSUM 불일치!"
    echo ""
    echo "  트러블슈팅:"
    echo "  1. 복제 지연 확인: SHOW SLAVE STATUS → Seconds_Behind_Master"
    echo "  2. 쓰기 진행 중이면 Master를 read_only로 설정 후 재검증"
    echo "  3. 특정 테이블만 불일치 → 해당 테이블 상세 비교:"
    echo "     SELECT * FROM <table> ORDER BY id DESC LIMIT 10;"
fi

echo ""
echo "  CSV 리포트: ${CSV_FILE}"
echo "  상세 로그:  ${LOG_FILE}"
