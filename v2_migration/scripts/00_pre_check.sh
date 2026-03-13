#!/usr/bin/env bash
# =============================================================================
# 00_pre_check.sh — DMS 마이그레이션 사전 검증 스크립트
# MySQL binlog 설정, 사용자 권한, 네트워크 연결, MongoDB 상태를 검증한다.
# =============================================================================
set -euo pipefail

# ─── 색상 정의 ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ─── 설정 (환경변수 또는 기본값) ───
MYSQL_HOST="${MYSQL_HOST:?'MYSQL_HOST 환경변수가 설정되지 않았습니다'}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:?'MYSQL_USER 환경변수가 설정되지 않았습니다'}"
MYSQL_PASS="${MYSQL_PASS:?'MYSQL_PASS 환경변수가 설정되지 않았습니다'}"
MYSQL_DB="${MYSQL_DB:-doktoridb}"

MONGO_HOST="${MONGO_HOST:?'MONGO_HOST 환경변수가 설정되지 않았습니다'}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_DB="${MONGO_DB:-doktori_chat}"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; ((PASS_COUNT++)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; ((FAIL_COUNT++)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; ((WARN_COUNT++)); }

mysql_query() {
    mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" \
        --skip-column-names --batch -e "$1" 2>/dev/null
}

# =============================================================================
echo "=========================================="
echo " DMS 마이그레이션 사전 검증"
echo "=========================================="
echo ""

# ─── 1. MySQL 연결 확인 ───
echo "1. MySQL 연결 확인"
if mysql_query "SELECT 1" > /dev/null 2>&1; then
    pass "MySQL 연결 성공 (${MYSQL_HOST}:${MYSQL_PORT})"
else
    fail "MySQL 연결 실패 (${MYSQL_HOST}:${MYSQL_PORT})"
    echo "  → MySQL 호스트, 포트, 자격증명을 확인하세요"
    exit 1
fi
echo ""

# ─── 2. binlog 설정 확인 ───
echo "2. MySQL binlog 설정 확인"

BINLOG_FORMAT=$(mysql_query "SELECT @@binlog_format")
if [ "$BINLOG_FORMAT" = "ROW" ]; then
    pass "binlog_format = ROW"
else
    fail "binlog_format = ${BINLOG_FORMAT} (ROW 필요)"
    echo "  → RDS 파라미터 그룹에서 binlog_format을 ROW로 변경하세요"
fi

LOG_BIN=$(mysql_query "SELECT @@log_bin")
if [ "$LOG_BIN" = "1" ] || [ "$LOG_BIN" = "ON" ]; then
    pass "Binary logging 활성화됨"
else
    fail "Binary logging 비활성화"
    echo "  → RDS: 자동 백업을 활성화하면 binlog가 활성화됩니다"
fi

BINLOG_ROW_IMAGE=$(mysql_query "SELECT @@binlog_row_image")
if [ "$BINLOG_ROW_IMAGE" = "FULL" ]; then
    pass "binlog_row_image = FULL"
else
    warn "binlog_row_image = ${BINLOG_ROW_IMAGE} (FULL 권장)"
fi

# binlog 보존 시간 확인 (RDS)
RETENTION=$(mysql_query "CALL mysql.rds_show_configuration" 2>/dev/null | grep "binlog retention hours" | awk '{print $NF}')
if [ -n "$RETENTION" ]; then
    if [ "$RETENTION" -ge 24 ]; then
        pass "binlog_retention_hours = ${RETENTION} (24시간 이상)"
    else
        fail "binlog_retention_hours = ${RETENTION} (최소 24시간 필요)"
        echo "  → CALL mysql.rds_set_configuration('binlog retention hours', 72);"
    fi
else
    warn "binlog_retention_hours 확인 불가 (non-RDS이거나 권한 부족)"
fi

# server_id 확인
SERVER_ID=$(mysql_query "SELECT @@server_id")
if [ "$SERVER_ID" -ge 1 ] 2>/dev/null; then
    pass "server_id = ${SERVER_ID} (1 이상)"
else
    fail "server_id = ${SERVER_ID} (1 이상 필요)"
fi
echo ""

# ─── 3. DMS 사용자 권한 확인 ───
echo "3. DMS 사용자 권한 확인"

GRANTS=$(mysql_query "SHOW GRANTS FOR CURRENT_USER()")

check_grant() {
    local priv="$1"
    if echo "$GRANTS" | grep -qi "$priv"; then
        pass "${priv} 권한 있음"
    else
        fail "${priv} 권한 없음"
        echo "  → GRANT ${priv} ON *.* TO '${MYSQL_USER}'@'%';"
    fi
}

check_grant "REPLICATION CLIENT"
check_grant "REPLICATION SLAVE"
check_grant "SELECT"
echo ""

# ─── 4. 대상 테이블 확인 ───
echo "4. 마이그레이션 대상 테이블 확인"

TABLES=("chatting_rooms" "room_rounds" "chatting_room_members" "messages" "quizzes" "quiz_choices")
for table in "${TABLES[@]}"; do
    COUNT=$(mysql_query "SELECT COUNT(*) FROM ${MYSQL_DB}.${table}" 2>/dev/null)
    if [ -n "$COUNT" ]; then
        pass "${table}: ${COUNT} rows"
    else
        fail "${table}: 테이블이 존재하지 않거나 접근 불가"
    fi
done
echo ""

# ─── 5. 데이터 타입 확인 (LOB, TEXT 등) ───
echo "5. 데이터 타입 확인 (LOB/TEXT 컬럼)"

LOB_COLS=$(mysql_query "
    SELECT CONCAT(TABLE_NAME, '.', COLUMN_NAME, ' (', DATA_TYPE, ', max=',
           IFNULL(CHARACTER_MAXIMUM_LENGTH, 'N/A'), ')')
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = '${MYSQL_DB}'
      AND TABLE_NAME IN ('chatting_rooms','room_rounds','chatting_room_members','messages','quizzes','quiz_choices')
      AND DATA_TYPE IN ('text','mediumtext','longtext','blob','mediumblob','longblob')
    ORDER BY TABLE_NAME, COLUMN_NAME
")

if [ -n "$LOB_COLS" ]; then
    warn "LOB/TEXT 컬럼 발견 (DMS LOB 모드 설정 필요):"
    echo "$LOB_COLS" | while read -r col; do
        echo "    - ${col}"
    done
else
    pass "LOB/TEXT 컬럼 없음 (Limited LOB 모드로 충분)"
fi
echo ""

# ─── 6. 문자셋 확인 ───
echo "6. 문자셋/콜레이션 확인"

DB_CHARSET=$(mysql_query "SELECT DEFAULT_CHARACTER_SET_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${MYSQL_DB}'")
DB_COLLATION=$(mysql_query "SELECT DEFAULT_COLLATION_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${MYSQL_DB}'")

if echo "$DB_CHARSET" | grep -qi "utf8mb4"; then
    pass "데이터베이스 문자셋: ${DB_CHARSET} / ${DB_COLLATION}"
else
    warn "데이터베이스 문자셋: ${DB_CHARSET} (utf8mb4 권장, 한글 인코딩 주의)"
fi
echo ""

# ─── 7. MongoDB 연결 확인 ───
echo "7. MongoDB 연결 확인"

if command -v mongosh &> /dev/null; then
    MONGO_CLI="mongosh"
elif command -v mongo &> /dev/null; then
    MONGO_CLI="mongo"
else
    warn "mongosh/mongo 클라이언트가 설치되지 않음 — MongoDB 연결 검증 생략"
    MONGO_CLI=""
fi

if [ -n "$MONGO_CLI" ]; then
    MONGO_RESULT=$($MONGO_CLI --host "$MONGO_HOST" --port "$MONGO_PORT" --eval "db.runCommand({ping:1}).ok" --quiet "$MONGO_DB" 2>/dev/null)
    if [ "$MONGO_RESULT" = "1" ]; then
        pass "MongoDB 연결 성공 (${MONGO_HOST}:${MONGO_PORT}/${MONGO_DB})"
    else
        fail "MongoDB 연결 실패 (${MONGO_HOST}:${MONGO_PORT})"
        echo "  → MongoDB 호스트, 포트, Security Group을 확인하세요"
    fi
fi
echo ""

# ─── 8. 네트워크 연결 확인 ───
echo "8. 네트워크 포트 연결 확인"

check_port() {
    local host="$1"
    local port="$2"
    local label="$3"
    if timeout 5 bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
        pass "${label} (${host}:${port}) 포트 열림"
    else
        fail "${label} (${host}:${port}) 포트 닫힘 — Security Group 확인 필요"
    fi
}

check_port "$MYSQL_HOST" "$MYSQL_PORT" "MySQL"
check_port "$MONGO_HOST" "$MONGO_PORT" "MongoDB"
echo ""

# ─── 9. RDS 스토리지 여유 확인 ───
echo "9. MySQL 스토리지 상태"

STORAGE_INFO=$(mysql_query "
    SELECT ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) AS size_mb
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = '${MYSQL_DB}'
      AND TABLE_NAME IN ('chatting_rooms','room_rounds','chatting_room_members','messages','quizzes','quiz_choices')
")

if [ -n "$STORAGE_INFO" ]; then
    pass "채팅 도메인 데이터 크기: ${STORAGE_INFO} MB"
    echo "  → binlog 보존 시 이 크기의 2~3배 스토리지 여유 필요"
else
    warn "스토리지 정보 조회 불가"
fi
echo ""

# ─── 결과 요약 ───
echo "=========================================="
echo " 검증 결과 요약"
echo "=========================================="
echo -e "  ${GREEN}PASS: ${PASS_COUNT}${NC}"
echo -e "  ${RED}FAIL: ${FAIL_COUNT}${NC}"
echo -e "  ${YELLOW}WARN: ${WARN_COUNT}${NC}"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${RED}FAIL 항목을 해결한 후 DMS 마이그레이션을 진행하세요.${NC}"
    exit 1
else
    echo -e "${GREEN}사전 검증 통과. DMS 마이그레이션을 진행할 수 있습니다.${NC}"
    exit 0
fi
