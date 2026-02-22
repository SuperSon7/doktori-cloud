#!/bin/bash
# ============================================================
# 03. RDS에서 Master-Slave 복제 설정
#
# 용도: RDS(Slave)가 dev MySQL(Master)을 바라보게 복제 연결
# 실행: RDS에 접속할 수 있는 환경에서 실행
#
# 사전 조건:
#   - 02-mysqldump.sh 로 덤프 생성 완료
#   - 덤프 파일을 RDS에 적재 완료
#   - Master에 복제 전용 유저 생성 완료
#   - Master ↔ RDS 간 네트워크 연결 확인 (SG 열려 있어야 함)
# ============================================================

set -euo pipefail

# ── 설정 (실행 전 수정 필요) ──
RDS_HOST="${RDS_HOST:-<RDS_ENDPOINT>}"
RDS_PORT="${RDS_PORT:-3306}"
RDS_USER="${RDS_USER:-admin}"
RDS_PASS="${RDS_PASS:-}"

MASTER_HOST="${MASTER_HOST:-<MASTER_PUBLIC_IP>}"  # dev 서버 IP (13.209.183.40)
MASTER_PORT="${MASTER_PORT:-3306}"                # Docker 포트 매핑 확인 (3306 or 3307)
REPL_USER="${REPL_USER:-repl_user}"
REPL_PASS="${REPL_PASS:-}"

# binlog position (02에서 생성된 파일에서 읽기)
POSITION_FILE="${POSITION_FILE:-/tmp/db-migration/binlog-position.txt}"

MYSQL_CMD="mysql -h${RDS_HOST} -P${RDS_PORT} -u${RDS_USER}"
[ -n "$RDS_PASS" ] && MYSQL_CMD="$MYSQL_CMD -p${RDS_PASS}"

echo "========================================"
echo " RDS Master-Slave 복제 설정"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""

# ── binlog position 읽기 ──
if [ -f "$POSITION_FILE" ]; then
    echo "  binlog position 파일에서 읽음:"
    MASTER_LOG_FILE=$(grep 'MASTER_LOG_FILE' "$POSITION_FILE" | cut -d'=' -f2)
    MASTER_LOG_POS=$(grep 'MASTER_LOG_POS' "$POSITION_FILE" | cut -d'=' -f2)
    echo ""
else
    echo "  ⚠️ binlog position 파일($POSITION_FILE)이 없습니다."
    echo "  수동으로 입력하세요:"
    read -p "  MASTER_LOG_FILE: " MASTER_LOG_FILE
    read -p "  MASTER_LOG_POS:  " MASTER_LOG_POS
    echo ""
fi

# ── 설정값 확인 ──
echo "  복제 설정 값:"
echo "    Master: ${MASTER_HOST}:${MASTER_PORT}"
echo "    Slave:  ${RDS_HOST}:${RDS_PORT}"
echo "    Repl User: ${REPL_USER}"
echo "    Log File:  ${MASTER_LOG_FILE}"
echo "    Log Pos:   ${MASTER_LOG_POS}"
echo ""
read -p "계속 진행하시겠습니까? (y/N): " CONFIRM
[ "$CONFIRM" != "y" ] && echo "취소됨." && exit 0

echo ""
# ── 복제 초기화 및 설정 ──
echo "[0/3] 기존 복제 설정 초기화 중..."
# 에러가 나더라도 무시하고 초기화를 진행하기 위해 2>/dev/null 혹은 || true 사용
$MYSQL_CMD -e "CALL mysql.rds_stop_replication;" 2>/dev/null || true
$MYSQL_CMD -e "CALL mysql.rds_reset_external_master;" 2>/dev/null || true
echo "  설정 초기화 완료 ✅"

echo ""
# ── 1. RDS에서 외부 Master 설정 ──
echo "[1/3] RDS에서 외부 Master 설정..."
echo ""
echo "  실행할 SQL:"
echo "  CALL mysql.rds_set_external_master("
echo "    '${MASTER_HOST}',"
echo "    ${MASTER_PORT},"
echo "    '${REPL_USER}',"
echo "    '***',"
echo "    '${MASTER_LOG_FILE}',"
echo "    ${MASTER_LOG_POS},"
echo "    0"
echo "  );"
echo ""

$MYSQL_CMD -e "
CALL mysql.rds_set_external_master(
    '${MASTER_HOST}',
    ${MASTER_PORT},
    '${REPL_USER}',
    '${REPL_PASS}',
    '${MASTER_LOG_FILE}',
    ${MASTER_LOG_POS},
    0
);
" 2>/dev/null

echo "  외부 Master 설정 완료 ✅"
echo ""

# ── 2. 복제 시작 ──
echo "[2/3] 복제 시작..."
$MYSQL_CMD -e "CALL mysql.rds_start_replication;" 2>/dev/null
echo "  복제 시작 ✅"
echo ""

# ── 3. 복제 상태 확인 ──
echo "[3/3] 복제 상태 확인..."
echo ""
sleep 3

$MYSQL_CMD -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_Error|Master_Host|Master_Port"

echo ""
echo "========================================"
echo " 결과 확인"
echo "========================================"
echo ""
echo "  Slave_IO_Running: Yes   ← 이것 확인"
echo "  Slave_SQL_Running: Yes  ← 이것 확인"
echo "  Seconds_Behind_Master: 0 수렴 ← 이것 관찰"
echo ""
echo "  복제 상태 모니터링: ./04-monitor-replication.sh"
echo "  데이터 정합성 검증: ./05-verify-data.sh"
