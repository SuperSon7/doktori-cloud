내가#!/bin/bash
set -e

SSH_KEY="${WIREMOCK_SSH_KEY:-~/.ssh/doktori-dev.pem}"
DEV_HOST="${WIREMOCK_DEV_HOST:-13.209.183.40}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ">> wiremock 파일 전송 중..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -r \
  "$SCRIPT_DIR/wiremock/mappings" \
  "$SCRIPT_DIR/wiremock/files" \
  ubuntu@${DEV_HOST}:~/wiremock/

echo ">> wiremock 컨테이너 실행 중..."
ssh -i "$SSH_KEY" ubuntu@${DEV_HOST} bash -s << 'REMOTE'
set -e
docker rm -f wiremock 2>/dev/null || true
mkdir -p ~/wiremock/mappings ~/wiremock/files

docker run -d --name wiremock -p 9090:8080 \
  -v ~/wiremock/mappings:/home/wiremock/mappings \
  -v ~/wiremock/files:/home/wiremock/__files \
  --restart unless-stopped \
  wiremock/wiremock:3.5.4 --verbose

# compose 네트워크 연결 (app_app-net)
NETWORK=$(docker network ls --format '{{.Name}}' | grep app-net | head -1)
if [ -n "$NETWORK" ]; then
  docker network connect "$NETWORK" wiremock
  echo ">> network connected: $NETWORK"
else
  echo ">> WARNING: app-net 네트워크를 찾을 수 없음"
fi

sleep 5
curl -sf http://localhost:9090/v3/search/book?query=test > /dev/null \
  && echo ">> wiremock 정상 동작 확인" \
  || echo ">> WARNING: wiremock 응답 실패"
REMOTE

echo ">> 완료"
echo ""
echo "내부 접근: http://wiremock:8080/v3/search/book"
echo "외부 접근: http://${DEV_HOST}:9090/v3/search/book"
echo "Admin API: http://${DEV_HOST}:9090/__admin/"