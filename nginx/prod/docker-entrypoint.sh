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

exec "$@"
