#!/bin/bash
set -e
exec > /var/log/user-data.log 2>&1

apt-get update
apt-get install -y git

# k6 바이너리 직접 설치 (ARM64) — GPG keyserver 의존성 제거
K6_VERSION="v0.54.0"
curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-arm64.tar.gz" \
  | tar xz --strip-components=1 -C /usr/local/bin

k6 version

cd /home/ubuntu
git clone https://github.com/100-hours-a-week/5-team-service-cloud.git
chown -R ubuntu:ubuntu 5-team-service-cloud

echo "=== runner setup done ==="