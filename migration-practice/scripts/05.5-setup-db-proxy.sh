#!/bin/bash
# ============================================================
# 05.5. Nginx Stream DB 프록시 설정
#
# 목적: 앱이 고정 엔드포인트(127.0.0.1:3307)로 DB에 접속하도록 구성.
#       컷오버 시 앱 재시작 없이 nginx upstream만 바꿔 무중단 전환.
#
# 원리:
#   앱(DB_URL) → 127.0.0.1:3307 → [nginx stream] → 실제 DB
#   - 평소: 127.0.0.1:3307 → localhost:3306 (로컬 MySQL)
#   - 컷오버: 127.0.0.1:3307 → RDS_HOST:3306 (nginx reload만으로 전환)
#
# 실행 시점: 컷오버 "전"에 미리 실행 (1회성)
#   이 스크립트로 프록시를 세팅하고, DB_URL을 고정 주소로 변경한 뒤
#   앱을 1회 재시작하면 이후 컷오버 때는 재시작 불필요.
#
# 실행: dev 서버에서 직접 실행
#   sudo bash 05.5-setup-db-proxy.sh
# ============================================================

set -euo pipefail

# ── 설정 ──
PROXY_LISTEN_PORT="${PROXY_LISTEN_PORT:-3307}"
LOCAL_MYSQL_HOST="${LOCAL_MYSQL_HOST:-127.0.0.1}"
LOCAL_MYSQL_PORT="${LOCAL_MYSQL_PORT:-3306}"
STREAM_CONF="/etc/nginx/stream.d/db-proxy.conf"
NGINX_CONF="/etc/nginx/nginx.conf"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

echo "========================================"
echo " Nginx Stream DB 프록시 설정"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""

# ============================================================
# STEP 1: Nginx stream 모듈 설치
# ============================================================
log "=== STEP 1: Nginx stream 모듈 확인/설치 ==="

# 이미 로드되어 있는지 확인
if nginx -V 2>&1 | grep -q "with-stream"; then
    log "  ✅ stream 모듈이 빌트인으로 포함됨"
elif [ -f /usr/lib/nginx/modules/ngx_stream_module.so ]; then
    log "  ✅ stream 모듈 파일 존재 (dynamic module)"
else
    log "  stream 모듈 설치 중..."
    apt-get update -qq
    apt-get install -y -qq libnginx-mod-stream
    log "  ✅ libnginx-mod-stream 설치 완료"
fi

# 실제 모듈 파일명 확인
STREAM_MODULE=$(ls /usr/lib/nginx/modules/ngx_stream_module.so 2>/dev/null || echo "")
if [ -z "$STREAM_MODULE" ]; then
    log "  ❌ stream 모듈 파일을 찾을 수 없습니다."
    exit 1
fi
echo ""

# ============================================================
# STEP 2: nginx.conf에 load_module 추가
# ============================================================
log "=== STEP 2: nginx.conf에 stream 모듈 로드 ==="

if grep -rq "ngx_stream_module" "$NGINX_CONF" /etc/nginx/modules-enabled/ 2>/dev/null; then
    log "  ✅ load_module 이미 존재 (modules-enabled 포함)"
else
    # nginx.conf 최상단에 추가
    sed -i '1i load_module modules/ngx_stream_module.so;' "$NGINX_CONF"
    log "  ✅ load_module 추가됨"
fi

# stream.d include 디렉토리가 없으면 추가
if ! grep -q "stream.d" "$NGINX_CONF"; then
    # http 블록 바로 앞에 stream include 추가
    sed -i '/^http {/i \
stream {\
    include /etc/nginx/stream.d/*.conf;\
}' "$NGINX_CONF"
    log "  ✅ stream { include } 블록 추가됨"
else
    log "  ✅ stream include 이미 존재"
fi
echo ""

# ============================================================
# STEP 3: stream.d 디렉토리 및 프록시 설정 생성
# ============================================================
log "=== STEP 3: DB 프록시 설정 파일 생성 ==="

mkdir -p /etc/nginx/stream.d

cat > "$STREAM_CONF" <<EOF
# DB 프록시 — 컷오버 시 upstream만 변경하고 nginx reload
#
# 현재: 로컬 MySQL (127.0.0.1:3306)
# 컷오버 후: 아래 proxy_pass를 RDS 엔드포인트로 변경
#
# 전환 방법:
#   1. proxy_pass 값을 RDS_HOST:3306 으로 수정
#   2. sudo nginx -t && sudo systemctl reload nginx

upstream db_backend {
    server ${LOCAL_MYSQL_HOST}:${LOCAL_MYSQL_PORT};
}

server {
    listen ${PROXY_LISTEN_PORT};
    proxy_pass db_backend;
    proxy_connect_timeout 3s;
    proxy_timeout 300s;
}
EOF

log "  ✅ ${STREAM_CONF} 생성됨"
log "  리슨: 127.0.0.1:${PROXY_LISTEN_PORT} → ${LOCAL_MYSQL_HOST}:${LOCAL_MYSQL_PORT}"
echo ""

# ============================================================
# STEP 4: Nginx 설정 테스트 및 reload
# ============================================================
log "=== STEP 4: Nginx 설정 테스트 및 reload ==="

if nginx -t 2>&1; then
    log "  ✅ nginx -t 통과"
    systemctl reload nginx
    log "  ✅ nginx reload 완료"
else
    log "  ❌ nginx -t 실패. 설정을 확인하세요."
    log "  복구: sudo rm ${STREAM_CONF} && sudo systemctl reload nginx"
    exit 1
fi
echo ""

# ============================================================
# STEP 5: 리슨 확인
# ============================================================
log "=== STEP 5: 프록시 포트 리슨 확인 ==="
sleep 1

if ss -lntp | grep -q ":${PROXY_LISTEN_PORT}"; then
    log "  ✅ 포트 ${PROXY_LISTEN_PORT} 리슨 중"
else
    log "  ❌ 포트 ${PROXY_LISTEN_PORT}이 리슨되지 않음. 로그를 확인하세요."
    journalctl -u nginx --no-pager -n 10
    exit 1
fi

# MySQL 연결 테스트
log "  MySQL 프록시 연결 테스트..."
if mysql -h127.0.0.1 -P${PROXY_LISTEN_PORT} -u${MASTER_USER:-doktori_prod]} -p${MASTER_PASS:-} -e "SELECT 1;" 2>/dev/null; then
    log "  ✅ 프록시 경유 MySQL 접속 성공"
else
    log "  ⚠️ MySQL 접속 테스트 실패 (MASTER_USER/MASTER_PASS 확인)"
    log "  수동 테스트: mysql -h127.0.0.1 -P${PROXY_LISTEN_PORT} -uroot -p"
fi
echo ""

# ============================================================
# 완료 안내
# ============================================================
echo "========================================"
echo " DB 프록시 설정 완료"
echo "========================================"
echo ""
echo "  프록시 주소: 127.0.0.1:${PROXY_LISTEN_PORT}"
echo "  현재 대상:   ${LOCAL_MYSQL_HOST}:${LOCAL_MYSQL_PORT} (로컬 MySQL)"
echo ""
echo "  다음 단계:"
echo "  1. Parameter Store의 DB_URL을 프록시 주소로 변경 (1회)"
echo "     jdbc:mysql://127.0.0.1:${PROXY_LISTEN_PORT}/doktoridb?..."
echo ""
echo "  2. 앱 재시작 (이것이 마지막 재시작)"
echo "     systemctl restart <앱서비스> 또는 앱 프로세스 재시작"
echo ""
echo "  3. 이후 컷오버(06) 시에는 앱 재시작 없이"
echo "     ${STREAM_CONF}의 upstream만 RDS로 변경 + nginx reload"
echo ""
echo "  설정 파일: ${STREAM_CONF}"
echo ""
