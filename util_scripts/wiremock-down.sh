#!/bin/bash
set -e

SSH_KEY="${WIREMOCK_SSH_KEY:-~/.ssh/doktori-dev.pem}"
DEV_HOST="${WIREMOCK_DEV_HOST:-13.209.183.40}"

echo ">> wiremock 컨테이너 제거 중..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${DEV_HOST} bash -s << 'REMOTE'
docker rm -f wiremock 2>/dev/null && echo ">> 컨테이너 제거 완료" || echo ">> 컨테이너 없음"
rm -rf ~/wiremock && echo ">> 파일 정리 완료"
REMOTE

echo ">> 완료"
echo ">> Parameter Store 원복 + reload-dev-backend.sh 실행 필요"