#!/bin/bash
# ============================================================
# 01. Master(dev MySQL) binlog/복제 설정 상태 확인
#
# 용도: 복제 시작 전 Master MySQL이 준비되어 있는지 점검
# 실행: dev 서버에서 실행
# ============================================================

set -euo pipefail

# ── 설정 ──
MYSQL_HOST="${MYSQL_HOST:-localhost}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-}"

MYSQL_CMD="mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USER}"
[ -n "$MYSQL_PASS" ] && MYSQL_CMD="$MYSQL_CMD -p${MYSQL_PASS}"

echo "========================================"
echo " Master MySQL 복제 준비 상태 점검"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""

# ── 1. MySQL 버전 ──
echo "[1/6] MySQL 버전"
$MYSQL_CMD -e "SELECT VERSION() AS mysql_version;" 2>/dev/null
echo ""

# ── 2. binlog 활성화 여부 ──
echo "[2/6] Binary Log 활성화 여부"
LOG_BIN=$($MYSQL_CMD -N -e "SHOW VARIABLES LIKE 'log_bin';" 2>/dev/null | awk '{print $2}')
if [ "$LOG_BIN" = "ON" ]; then
    echo "  log_bin = ON  ✅"
else
    echo "  log_bin = OFF  ❌"
    echo ""
    echo "  [조치 필요] my.cnf에 아래 설정 추가 후 MySQL 재시작:"
    echo "    [mysqld]"
    echo "    log_bin = mysql-bin"
    echo "    binlog_format = ROW"
    echo "    server-id = 1"
    echo ""
    echo "  Docker라면 docker-compose.yml에 command 추가:"
    echo "    command: --log-bin=mysql-bin --binlog-format=ROW --server-id=1"
fi
echo ""

# ── 3. binlog 포맷 ──
echo "[3/6] Binary Log 포맷"
BINLOG_FORMAT=$($MYSQL_CMD -N -e "SHOW VARIABLES LIKE 'binlog_format';" 2>/dev/null | awk '{print $2}')
if [ "$BINLOG_FORMAT" = "ROW" ]; then
    echo "  binlog_format = ROW  ✅"
else
    echo "  binlog_format = $BINLOG_FORMAT  ⚠️"
    echo "  [권장] ROW 포맷으로 변경 필요 (STATEMENT는 복제 시 데이터 불일치 위험)"
fi
echo ""

# ── 4. server-id ──
echo "[4/6] Server ID"
SERVER_ID=$($MYSQL_CMD -N -e "SHOW VARIABLES LIKE 'server_id';" 2>/dev/null | awk '{print $2}')
if [ "$SERVER_ID" != "0" ] && [ -n "$SERVER_ID" ]; then
    echo "  server_id = $SERVER_ID  ✅"
else
    echo "  server_id = $SERVER_ID  ❌ (0이면 복제 불가)"
fi
echo ""

# ── 5. 현재 binlog 위치 ──
echo "[5/6] 현재 Binary Log 위치"
$MYSQL_CMD -e "SHOW MASTER STATUS\G" 2>/dev/null || echo "  (binlog 비활성화 상태)"
echo ""

# ── 6. 복제 전용 유저 존재 여부 ──
echo "[6/6] 복제 전용 유저 확인"
REPL_USER=$($MYSQL_CMD -N -e "SELECT user FROM mysql.user WHERE Repl_slave_priv = 'Y' AND user != 'root';" 2>/dev/null)
if [ -n "$REPL_USER" ]; then
    echo "  복제 권한 유저: $REPL_USER  ✅"
else
    echo "  복제 전용 유저 없음  ⚠️"
    echo ""
    echo "  [생성 명령어]"
    echo "  CREATE USER 'repl_user'@'%' IDENTIFIED BY '<비밀번호>';"
    echo "  GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';"
    echo "  FLUSH PRIVILEGES;"
fi

echo ""
echo "========================================"
echo " 점검 완료"
echo "========================================"
echo ""
echo "모든 항목이 ✅ 이면 02-mysqldump.sh 로 진행하세요."
echo "❌/⚠️ 항목이 있으면 조치 후 이 스크립트를 다시 실행하세요."
