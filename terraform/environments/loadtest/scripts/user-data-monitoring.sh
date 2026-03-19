#!/bin/bash
set -e
exec > /var/log/user-data.log 2>&1

apt-get update
apt-get install -y git

# ── k6 바이너리 직접 설치 (ARM64) ──
K6_VERSION="v0.54.0"
curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-arm64.tar.gz" \
  | tar xz --strip-components=1 -C /usr/local/bin

k6 version

cd /home/ubuntu
git clone https://github.com/100-hours-a-week/5-team-service-cloud.git
chown -R ubuntu:ubuntu 5-team-service-cloud

# ── Docker 설치 ──
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu

# ── 모니터링 스택 설정 ──
mkdir -p /home/ubuntu/monitoring/grafana/provisioning/datasources

# Prometheus 설정 (remote write receiver로 k6 메트릭 수신)
printf 'global:\n  scrape_interval: 5s\n' > /home/ubuntu/monitoring/prometheus.yml

# Grafana 데이터소스 자동 프로비저닝
printf 'apiVersion: 1\ndatasources:\n  - name: Prometheus\n    type: prometheus\n    access: proxy\n    url: http://prometheus:9090\n    isDefault: true\n' \
  > /home/ubuntu/monitoring/grafana/provisioning/datasources/prometheus.yml

# docker-compose (inline YAML, heredoc 사용 안 함)
printf 'services:\n  prometheus:\n    image: prom/prometheus:latest\n    container_name: prometheus\n    command: ["--config.file=/etc/prometheus/prometheus.yml","--web.enable-remote-write-receiver","--storage.tsdb.retention.time=7d"]\n    ports: ["9090:9090"]\n    volumes: ["./prometheus.yml:/etc/prometheus/prometheus.yml","prometheus-data:/prometheus"]\n    restart: unless-stopped\n  grafana:\n    image: grafana/grafana:latest\n    container_name: grafana\n    ports: ["3000:3000"]\n    environment: ["GF_SECURITY_ADMIN_PASSWORD=loadtest","GF_AUTH_ANONYMOUS_ENABLED=true","GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer"]\n    volumes: ["./grafana/provisioning:/etc/grafana/provisioning","grafana-data:/var/lib/grafana"]\n    depends_on: [prometheus]\n    restart: unless-stopped\nvolumes:\n  grafana-data:\n  prometheus-data:\n' \
  > /home/ubuntu/monitoring/docker-compose.yml

chown -R ubuntu:ubuntu /home/ubuntu/monitoring

cd /home/ubuntu/monitoring
docker compose up -d

echo "=== monitoring + runner setup done ==="