#!/bin/sh
set -e

# upstream.conf — IP 변수만 치환 (nginx $host 등은 보존)
envsubst '$API_IP $CHAT_IP $AI_IP $FRONT_IP' \
  < /etc/nginx/templates/upstream.conf.template \
  > /etc/nginx/conf.d/upstream.conf

# default site — DOMAIN만 치환
envsubst '$DOMAIN' \
  < /etc/nginx/templates/default.conf.template \
  > /etc/nginx/conf.d/default.conf

# sites-enabled 디렉토리 정리 (conf.d로 통합)
rm -rf /etc/nginx/sites-enabled /etc/nginx/sites-available

# Blue/Green 상태 복원 — CI/CD가 기록한 활성 포트를 컨테이너 재시작 시 유지
# 상태 파일: /etc/nginx/state/active-port-{api,chat} (docker volume으로 영속화)
STATE_DIR="/etc/nginx/state"
if [ -f "${STATE_DIR}/active-port-api" ]; then
  ACTIVE_API_PORT=$(cat "${STATE_DIR}/active-port-api")
  sed -i -E "s/:# Blue/Green 상태 복원 — CI/CD가 기록한 활성 포트를 컨테이너 재시작 시 유지
                # 상태 파일: /etc/nginx/state/active-port-{api,chat} (docker volume으로 영속화)
                STATE_DIR="/etc/nginx/state"
                if [ -f "${STATE_DIR}/active-port-api" ]; then
                  ACTIVE_API_PORT=$(cat "${STATE_DIR}/active-port-api")
                  sed -i -E "s/:[0-9]+;/:${ACTIVE_API_PORT};/" /etc/nginx/conf.d/upstream-api.conf
                  echo "[entrypoint] Restored API upstream to port ${ACTIVE_API_PORT}"
                fi

                if [ -f "${STATE_DIR}/active-port-chat" ]; then
                  ACTIVE_CHAT_PORT=$(cat "${STATE_DIR}/active-port-chat")
                  sed -i -E "s/:[0-9]+;/:${ACTIVE_CHAT_PORT};/" /etc/nginx/conf.d/upstream-chat.conf
                  echo "[entrypoint] Restored Chat upstream to port ${ACTIVE_CHAT_PORT}"
                fi[0-9]+;/:${ACTIVE_API_PORT};/" /etc/nginx/conf.d/upstream-api.conf
  echo "[entrypoint] Restored API upstream to port ${ACTIVE_API_PORT}"
fi

if [ -f "${STATE_DIR}/active-port-chat" ]; then
  ACTIVE_CHAT_PORT=$(cat "${STATE_DIR}/active-port-chat")
  sed -i -E "s/:[0-9]+;/:${ACTIVE_CHAT_PORT};/" /etc/nginx/conf.d/upstream-chat.conf
  echo "[entrypoint] Restored Chat upstream to port ${ACTIVE_CHAT_PORT}"
fi

exec "$@"
