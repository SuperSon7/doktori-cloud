#!/bin/sh
set -e

# Upstream templates — 서비스별 분리, 각각 필요한 변수만 치환
envsubst '$API_IP' \
  < /etc/nginx/templates/upstream-api.conf.template \
  > /etc/nginx/conf.d/upstream-api.conf

envsubst '$CHAT_IP' \
  < /etc/nginx/templates/upstream-chat.conf.template \
  > /etc/nginx/conf.d/upstream-chat.conf

envsubst '$AI_IP' \
  < /etc/nginx/templates/upstream-ai.conf.template \
  > /etc/nginx/conf.d/upstream-ai.conf

envsubst '$FRONT_IP' \
  < /etc/nginx/templates/upstream-frontend.conf.template \
  > /etc/nginx/conf.d/upstream-frontend.conf

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
