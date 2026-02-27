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

exec "$@"
