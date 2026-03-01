#!/bin/bash
set -e

# -----------------------------------------------------------------------------
# User Data Script for Nginx Reverse Proxy (Ubuntu 22.04 ARM64)
# Project: ${project_name}
# Environment: ${environment}
# Domain: ${domain}
# Docker-based nginx deployment (image pulled from ECR)
# -----------------------------------------------------------------------------

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Starting nginx user data script ==="

export DEBIAN_FRONTEND=noninteractive

# Lock cleanup
killall apt apt-get 2>/dev/null || true
rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock

# -----------------------------------------------------------------------------
# System Update
# -----------------------------------------------------------------------------
echo "=== Updating system packages ==="
apt-get update
apt-get upgrade -y

# -----------------------------------------------------------------------------
# Install Docker
# -----------------------------------------------------------------------------
echo "=== Installing Docker ==="
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker ubuntu
systemctl enable docker

# -----------------------------------------------------------------------------
# Install AWS CLI v2 (aarch64)
# -----------------------------------------------------------------------------
echo "=== Installing AWS CLI v2 (aarch64) ==="
curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
apt-get install -y unzip
unzip -q awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

# -----------------------------------------------------------------------------
# SSM Agent
# -----------------------------------------------------------------------------
echo "=== Ensuring SSM Agent is running ==="
snap install amazon-ssm-agent --classic 2>/dev/null || true
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service

# -----------------------------------------------------------------------------
# Useful tools
# -----------------------------------------------------------------------------
apt-get install -y htop vim curl wget jq net-tools tree

# -----------------------------------------------------------------------------
# Timezone
# -----------------------------------------------------------------------------
timedatectl set-timezone Asia/Seoul

# -----------------------------------------------------------------------------
# Certbot / Let's Encrypt (호스트에서 관리)
# -----------------------------------------------------------------------------
echo "=== Setting up Certbot ==="
apt-get install -y certbot
mkdir -p /var/www/certbot

# -----------------------------------------------------------------------------
# ECR Login & Docker Pull
# -----------------------------------------------------------------------------
echo "=== Pulling nginx image from ECR ==="
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region ${aws_region} | \
  docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.${aws_region}.amazonaws.com"

IMAGE="$ACCOUNT_ID.dkr.ecr.${aws_region}.amazonaws.com/${project_name}/nginx:latest"
docker pull "$IMAGE"

# -----------------------------------------------------------------------------
# Run Nginx Container
# -----------------------------------------------------------------------------
echo "=== Starting nginx container ==="
docker run -d \
  --name nginx \
  --restart unless-stopped \
  --network host \
  -e API_IP=${api_ip} \
  -e CHAT_IP=${chat_ip} \
  -e AI_IP=${ai_ip} \
  -e FRONT_IP=${front_ip} \
  -e DOMAIN=${domain} \
  -v /etc/letsencrypt:/etc/letsencrypt:ro \
  -v /var/www/certbot:/var/www/certbot:ro \
  -v nginx-logs:/var/log/nginx \
  "$IMAGE"

# -----------------------------------------------------------------------------
# ECR login helper
# -----------------------------------------------------------------------------
cat > /home/ubuntu/ecr-login.sh << 'ECREOF'
#!/bin/bash
REGION=$(TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") && \
  curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
ECREOF
chmod +x /home/ubuntu/ecr-login.sh
chown ubuntu:ubuntu /home/ubuntu/ecr-login.sh

# -----------------------------------------------------------------------------
# Monitoring Agent (Alloy + cAdvisor + nginx-exporter)
# -----------------------------------------------------------------------------
echo "=== Setting up monitoring agent ==="
mkdir -p /home/ubuntu/monitoring/alloy

# docker-compose — Alloy + cAdvisor + nginx-exporter
cat > /home/ubuntu/monitoring/docker-compose.yml << 'MONCOMPOSEEOF'
services:
  alloy:
    image: grafana/alloy:v1.9.0
    container_name: alloy
    command:
      - run
      - /etc/alloy/config.alloy
      - --server.http.listen-addr=0.0.0.0:12345
      - --storage.path=/var/lib/alloy/data
    network_mode: host
    pid: host
    volumes:
      - alloy-data:/var/lib/alloy/data
      - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/host/root:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - MONITORING_IP=__MONITORING_IP__
      - ALLOY_ENV=prod
      - INSTANCE_NAME=nginx
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  cadvisor:
    image: ghcr.io/google/cadvisor:latest
    container_name: cadvisor
    network_mode: host
    command: ["-port=9101"]
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    privileged: true
    devices:
      - /dev/kmsg
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "2"

  nginx-exporter:
    image: nginx/nginx-prometheus-exporter:1.4
    container_name: nginx-exporter
    network_mode: host
    command:
      - --nginx.scrape-uri=http://localhost:8888/nginx_status
      - --web.listen-address=:9113
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "2"

volumes:
  alloy-data:
MONCOMPOSEEOF

sed -i "s/__MONITORING_IP__/${monitoring_ip}/g" /home/ubuntu/monitoring/docker-compose.yml

# Alloy config — nginx variant
cat > /home/ubuntu/monitoring/alloy/config.alloy << 'ALLOYEOF'
// Grafana Alloy — Prod nginx
prometheus.exporter.unix "host" {
  procfs_path = "/host/proc"
  sysfs_path  = "/host/sys"
  rootfs_path = "/host/root"
  enable_collectors = [
    "cpu", "meminfo", "diskstats", "filesystem",
    "loadavg", "netdev", "uname", "time",
  ]
  filesystem {
    mount_points_exclude = "^/(dev|proc|sys|run|host)($|/)"
  }
}

prometheus.scrape "host_metrics" {
  targets         = prometheus.exporter.unix.host.targets
  forward_to      = [prometheus.relabel.add_env.receiver]
  scrape_interval = "15s"
}

prometheus.scrape "cadvisor" {
  targets = [
    { "__address__" = "localhost:9101", "app" = "cadvisor" },
  ]
  scrape_interval = "15s"
  forward_to      = [prometheus.relabel.add_env.receiver]
}

prometheus.scrape "nginx" {
  targets = [
    { "__address__" = "localhost:9113", "app" = "nginx" },
  ]
  scrape_interval = "15s"
  forward_to      = [prometheus.relabel.add_env.receiver]
}

prometheus.relabel "add_env" {
  rule {
    target_label = "env"
    replacement  = sys.env("ALLOY_ENV")
  }
  rule {
    source_labels = ["app"]
    regex         = "(.+)"
    target_label  = "instance"
  }
  rule {
    source_labels = ["job"]
    regex         = "prometheus\\.(?:scrape|exporter)\\.(.+?)(?:_metrics)?"
    target_label  = "job"
    replacement   = "$1"
  }
  rule {
    source_labels = ["job"]
    regex         = "(.+)_(.+)"
    target_label  = "job"
    replacement   = "$1-$2"
  }
  forward_to = [prometheus.remote_write.monitoring.receiver]
}

prometheus.remote_write "monitoring" {
  endpoint {
    url = "http://" + sys.env("MONITORING_IP") + ":9090/api/v1/write"
  }
}

discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

discovery.relabel "docker_logs" {
  targets = discovery.docker.containers.targets
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/.*(alloy|cadvisor|nginx-exporter).*"
    action        = "drop"
  }
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.+)"
    target_label  = "app"
  }
}

loki.source.docker "containers" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.relabel.docker_logs.output
  forward_to = [loki.relabel.add_env.receiver]
}

loki.relabel "add_env" {
  rule {
    target_label = "env"
    replacement  = sys.env("ALLOY_ENV")
  }
  rule {
    source_labels = ["app"]
    regex         = "(.+)"
    target_label  = "instance"
  }
  forward_to = [loki.write.monitoring.receiver]
}

loki.write "monitoring" {
  endpoint {
    url = "http://" + sys.env("MONITORING_IP") + ":3100/loki/api/v1/push"
  }
}
ALLOYEOF

chown -R ubuntu:ubuntu /home/ubuntu/monitoring

echo "=== Starting monitoring stack ==="
cd /home/ubuntu/monitoring && docker compose up -d

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
echo "==========================================="
echo "   Installation Verification"
echo "==========================================="
echo "Docker: $(docker --version)"
echo "AWS CLI: $(aws --version)"
echo "SSM Agent: $(systemctl is-active snap.amazon-ssm-agent.amazon-ssm-agent.service)"
echo "Certbot: $(certbot --version 2>&1)"
echo "Nginx container: $(docker ps --filter name=nginx --format '{{.Status}}')"
echo "Monitoring: $(docker ps --filter name=alloy --filter name=cadvisor --filter name=nginx-exporter --format '{{.Names}}: {{.Status}}')"
echo "=== Nginx user data script completed ==="
