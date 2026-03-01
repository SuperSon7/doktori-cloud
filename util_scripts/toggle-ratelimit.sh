#!/bin/bash
set -e

SSH_KEY="${DEV_SSH_KEY:-~/.ssh/doktori-dev.pem}"
DEV_HOST="${DEV_HOST:-13.209.183.40}"
ACTION="${1:-status}"

case "$ACTION" in
  off)
    echo ">> rate limit 비활성화 중..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${DEV_HOST} \
      "sed -i 's/^\(\s*limit_req\)/#\1/' /home/ubuntu/app/nginx.conf && docker compose -f /home/ubuntu/app/docker-compose.yml restart nginx"
    echo ">> 완료 (rate limit OFF)"
    ;;
  on)
    echo ">> rate limit 활성화 중..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${DEV_HOST} \
      "sed -i 's/^#\(\s*limit_req\)/\1/' /home/ubuntu/app/nginx.conf && docker compose -f /home/ubuntu/app/docker-compose.yml restart nginx"
    echo ">> 완료 (rate limit ON)"
    ;;
  status)
    echo "== 현재 상태 =="
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${DEV_HOST} \
      "docker exec app-nginx-1 grep -n 'limit_req' /etc/nginx/nginx.conf"
    ;;
  *)
    echo "사용법: $0 {on|off|status}"
    exit 1
    ;;
esac