#!/bin/bash
# ============================================================
# 04. 복제 상태 실시간 모니터링
#
# 용도: Seconds_Behind_Master, IO/SQL 스레드 상태를 지속 관찰
# 실행: RDS에 접속할 수 있는 환경에서 실행
# 종료: Ctrl+C
# ============================================================

set -euo pipefail

# ── 설정 ──
RDS_HOST="${RDS_HOST:-<RDS_ENDPOINT>}"
RDS_PORT="${RDS_PORT:-3306}"
RDS_USER="${RDS_USER:-admin}"
RDS_PASS="${RDS_PASS:-}"
INTERVAL="${INTERVAL:-3}"  # 관찰 간격 (초)

MYSQL_CMD="mysql -h${RDS_HOST} -P${RDS_PORT} -u${RDS_USER}"
[ -n "$RDS_PASS" ] && MYSQL_CMD="$MYSQL_CMD -p${RDS_PASS}"

LOG_FILE="/tmp/db-migration/replication-monitor-$(date +%Y%m%d-%H%M%S).log"
mkdir -p /tmp/db-migration

echo "========================================"
echo " 복제 상태 모니터링"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo " 간격: ${INTERVAL}초  |  로그: ${LOG_FILE}"
echo " 종료: Ctrl+C"
echo "========================================"
echo ""
printf "%-20s | %-5s | %-5s | %-8s | %s\n" "시간" "IO" "SQL" "Lag(s)" "Error"
echo "----------------------------------------------------------------------"

# 헤더를 로그에도 기록
echo "timestamp,io_running,sql_running,seconds_behind,last_error" > "$LOG_FILE"

while true; do
    TIMESTAMP=$(date '+%H:%M:%S')

    # SHOW SLAVE STATUS 결과 파싱
    STATUS=$($MYSQL_CMD -N -e "SHOW SLAVE STATUS\G" 2>/dev/null)

    IO_RUNNING=$(echo "$STATUS" | grep "Slave_IO_Running:" | awk '{print $2}')
    SQL_RUNNING=$(echo "$STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')
    LAG=$(echo "$STATUS" | grep "Seconds_Behind_Master:" | awk '{print $2}')
    LAST_ERR=$(echo "$STATUS" | grep "Last_Error:" | sed 's/.*Last_Error: //')

    # 상태별 색상
    IO_ICON="✅"
    SQL_ICON="✅"
    LAG_DISPLAY="$LAG"

    [ "$IO_RUNNING" != "Yes" ] && IO_ICON="❌"
    [ "$SQL_RUNNING" != "Yes" ] && SQL_ICON="❌"
    [ "$LAG" = "NULL" ] && LAG_DISPLAY="NULL ❌"
    [ "$LAG" != "NULL" ] && [ "$LAG" != "0" ] && LAG_DISPLAY="$LAG ⚠️"
    [ "$LAG" = "0" ] && LAG_DISPLAY="0 ✅"

    # 에러 축약
    ERR_SHORT=""
    [ -n "$LAST_ERR" ] && ERR_SHORT=$(echo "$LAST_ERR" | cut -c1-40)

    printf "%-20s | %-5s | %-5s | %-8s | %s\n" \
        "$TIMESTAMP" "$IO_ICON" "$SQL_ICON" "$LAG_DISPLAY" "$ERR_SHORT"

    # CSV 로그 기록
    echo "${TIMESTAMP},${IO_RUNNING},${SQL_RUNNING},${LAG},${LAST_ERR}" >> "$LOG_FILE"

    # 이상 감지 시 경고
    if [ "$IO_RUNNING" != "Yes" ] || [ "$SQL_RUNNING" != "Yes" ]; then
        echo "  ⚠️⚠️⚠️  복제 중단 감지! SHOW SLAVE STATUS 전체 확인 필요  ⚠️⚠️⚠️"
    fi

    sleep "$INTERVAL"
done
