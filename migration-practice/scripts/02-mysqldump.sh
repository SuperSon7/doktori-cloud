#!/bin/bash
# ============================================================
# 02. Master DB 덤프 (binlog position 포함)
#
# 용도: RDS에 초기 데이터 적재용 덤프 파일 생성
# 실행: dev 서버(Master)에서 실행
#
# 주의: --master-data=2 옵션으로 binlog position이 주석으로 기록됨
#       이 position을 03에서 RDS 복제 설정 시 사용
# ============================================================

set -euo pipefail

# ── 설정 ──
MYSQL_HOST="${MYSQL_HOST:-localhost}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-}"
DB_NAME="${DB_NAME:-doktoridb}"
DUMP_DIR="${DUMP_DIR:-/tmp/db-migration}"
DUMP_FILE="${DUMP_DIR}/master-dump-$(date +%Y%m%d-%H%M%S).sql"

mkdir -p "$DUMP_DIR"

MYSQLDUMP_CMD="mysqldump -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USER}"
[ -n "$MYSQL_PASS" ] && MYSQLDUMP_CMD="$MYSQLDUMP_CMD -p${MYSQL_PASS}"

echo "========================================"
echo " Master DB 덤프 시작"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""
echo "  DB:   $DB_NAME"
echo "  출력: $DUMP_FILE"
echo ""

# ── 덤프 전 binlog 위치 기록 ──
echo "[1/3] 덤프 전 binlog 위치 확인..."
MYSQL_CMD="mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USER}"
[ -n "$MYSQL_PASS" ] && MYSQL_CMD="$MYSQL_CMD -p${MYSQL_PASS}"
$MYSQL_CMD -e "SHOW MASTER STATUS\G" 2>/dev/null
echo ""

# ── 덤프 실행 ──
echo "[2/3] mysqldump 실행 중... (데이터 크기에 따라 수 분 소요)"
START_TIME=$(date +%s)

$MYSQLDUMP_CMD \
    --single-transaction \
    --master-data=2 \
    --routines \
    --triggers \
    --events \
    --set-gtid-purged=OFF \
    "$DB_NAME" > "$DUMP_FILE" 2>/dev/null

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo "  덤프 완료 (${ELAPSED}초 소요)"
echo ""

# ── 덤프 파일 정보 ──
echo "[3/3] 덤프 파일 정보"
DUMP_SIZE=$(ls -lh "$DUMP_FILE" | awk '{print $5}')
echo "  파일: $DUMP_FILE"
echo "  크기: $DUMP_SIZE"
echo ""

# ── binlog position 추출 ──
echo "========================================"
echo " binlog position (RDS 복제 설정 시 사용)"
echo "========================================"
BINLOG_LINE=$(grep -m1 "CHANGE MASTER TO" "$DUMP_FILE" 2>/dev/null || echo "NOT FOUND")
if [ "$BINLOG_LINE" != "NOT FOUND" ]; then
    BINLOG_FILE=$(echo "$BINLOG_LINE" | grep -oP "MASTER_LOG_FILE='[^']+'" | cut -d"'" -f2)
    BINLOG_POS=$(echo "$BINLOG_LINE" | grep -oP "MASTER_LOG_POS=\d+" | cut -d= -f2)
    echo ""
    echo "  MASTER_LOG_FILE = $BINLOG_FILE"
    echo "  MASTER_LOG_POS  = $BINLOG_POS"
    echo ""
    echo "  → 이 값을 03-setup-replication.sh 에서 사용하세요."

    # position을 별도 파일로 저장
    cat > "${DUMP_DIR}/binlog-position.txt" <<EOF
MASTER_LOG_FILE=${BINLOG_FILE}
MASTER_LOG_POS=${BINLOG_POS}
DUMP_FILE=${DUMP_FILE}
DUMP_TIME=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    echo "  → ${DUMP_DIR}/binlog-position.txt 에도 저장됨"
else
    echo "  ⚠️ binlog position을 찾을 수 없습니다."
    echo "  --master-data=2 옵션이 적용되지 않았을 수 있습니다."
    echo "  binlog가 활성화되어 있는지 01-check-master-status.sh 로 확인하세요."
fi

echo ""
echo "========================================"
echo " 다음 단계"
echo "========================================"
echo ""
echo "1. 덤프 파일을 RDS에 적재:"
echo "   mysql -h <RDS_ENDPOINT> -u <USER> -p $DB_NAME < $DUMP_FILE"
echo ""
echo "2. 적재 완료 후 03-setup-replication.sh 실행"
