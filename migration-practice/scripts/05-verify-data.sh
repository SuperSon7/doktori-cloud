#!/bin/bash
# ============================================================
# 05. Master ↔ Slave 데이터 정합성 검증
#
# 용도: 복제 후 양쪽 DB의 데이터가 일치하는지 확인
# 실행: 양쪽 DB에 접속 가능한 환경에서 실행
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

MASTER_CMD="mysql -h${MASTER_HOST} -P${MASTER_PORT} -u${MASTER_USER} -N"
RDS_CMD="mysql -h${RDS_HOST} -P${RDS_PORT} -u${RDS_USER} -N"
[ -n "$MASTER_PASS" ] && MASTER_CMD="$MASTER_CMD -p${MASTER_PASS}"
[ -n "$RDS_PASS" ] && RDS_CMD="$RDS_CMD -p${RDS_PASS}"

echo "========================================"
echo " Master ↔ Slave 데이터 정합성 검증"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""
echo "  Master: ${MASTER_HOST}:${MASTER_PORT}"
echo "  Slave:  ${RDS_HOST}:${RDS_PORT}"
echo "  DB:     ${DB_NAME}"
echo ""

# ── 1. 테이블 목록 비교 ──
echo "[1/3] 테이블 목록 비교"
MASTER_TABLES=$($MASTER_CMD -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DB_NAME}' ORDER BY TABLE_NAME;" 2>/dev/null)
RDS_TABLES=$($RDS_CMD -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DB_NAME}' ORDER BY TABLE_NAME;" 2>/dev/null)

if [ "$MASTER_TABLES" = "$RDS_TABLES" ]; then
    TABLE_COUNT=$(echo "$MASTER_TABLES" | wc -l | tr -d ' ')
    echo "  테이블 목록 일치 ✅ (${TABLE_COUNT}개)"
else
    echo "  테이블 목록 불일치 ❌"
    echo ""
    echo "  Master에만 있는 테이블:"
    diff <(echo "$MASTER_TABLES") <(echo "$RDS_TABLES") | grep "^<" | sed 's/^< /    /'
    echo "  Slave에만 있는 테이블:"
    diff <(echo "$MASTER_TABLES") <(echo "$RDS_TABLES") | grep "^>" | sed 's/^> /    /'
fi
echo ""

# ── 2. 각 테이블 row count 비교 ──
echo "[2/3] 테이블별 Row Count 비교"
echo ""
printf "  %-40s | %10s | %10s | %s\n" "테이블" "Master" "Slave" "상태"
echo "  ---------------------------------------------------------------------------"

MISMATCH=0
while IFS= read -r TABLE; do
    [ -z "$TABLE" ] && continue

    M_COUNT=$($MASTER_CMD -e "SELECT COUNT(*) FROM ${DB_NAME}.${TABLE};" 2>/dev/null | tr -d '[:space:]')
    R_COUNT=$($RDS_CMD -e "SELECT COUNT(*) FROM ${DB_NAME}.${TABLE};" 2>/dev/null | tr -d '[:space:]')

    if [ "$M_COUNT" = "$R_COUNT" ]; then
        STATUS="✅"
    else
        STATUS="❌ (차이: $((M_COUNT - R_COUNT)))"
        MISMATCH=$((MISMATCH + 1))
    fi

    printf "  %-40s | %10s | %10s | %s\n" "$TABLE" "$M_COUNT" "$R_COUNT" "$STATUS"
done <<< "$MASTER_TABLES"

echo ""
if [ "$MISMATCH" -eq 0 ]; then
    echo "  모든 테이블 row count 일치 ✅"
else
    echo "  ${MISMATCH}개 테이블 불일치 ❌"
    echo "  → 복제 지연(Seconds_Behind_Master > 0)이면 잠시 대기 후 재실행"
fi
echo ""

# ── 3. 최근 데이터 샘플 비교 ──
echo "[3/3] 최근 데이터 샘플 비교 (주요 테이블)"
echo ""

# meetings 테이블 최근 5건
echo "  [meetings] 최근 5건:"
echo "    Master:"
$MASTER_CMD -e "SELECT id, title, created_at FROM ${DB_NAME}.meetings ORDER BY id DESC LIMIT 5;" 2>/dev/null | while read -r line; do
    echo "      $line"
done
echo "    Slave:"
$RDS_CMD -e "SELECT id, title, created_at FROM ${DB_NAME}.meetings ORDER BY id DESC LIMIT 5;" 2>/dev/null | while read -r line; do
    echo "      $line"
done

echo ""
echo "========================================"
echo " 검증 완료"
echo "========================================"
echo ""
if [ "$MISMATCH" -eq 0 ]; then
    echo "  ✅ 데이터 정합성 확인 — 컷오버 진행 가능"
    echo "  → 06-cutover-rehearsal.sh 로 진행하세요."
else
    echo "  ❌ 불일치 발견 — 복제 상태 확인 후 재검증 필요"
    echo "  → 04-monitor-replication.sh 로 Seconds_Behind_Master 확인"
fi
