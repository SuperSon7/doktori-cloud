#!/bin/bash
set -e

# -----------------------------------------------------------------------------
# User Data Script for Prod App (Ubuntu 22.04 ARM64)
# Project: ${project_name}
# Environment: ${environment}
# Service: ${service_name}
# Pre-baked AMI base: Docker CE, AWS CLI v2, SSM Agent
# -----------------------------------------------------------------------------

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Starting user data script ==="
echo "Project: ${project_name}"
echo "Environment: ${environment}"
echo "Service: ${service_name}"

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
# SSM Agent (pre-installed on Ubuntu AMI, ensure running)
# -----------------------------------------------------------------------------
echo "=== Ensuring SSM Agent is running ==="
snap install amazon-ssm-agent --classic 2>/dev/null || true
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service

# -----------------------------------------------------------------------------
# Useful tools
# -----------------------------------------------------------------------------
echo "=== Installing additional tools ==="
apt-get install -y htop vim curl wget jq net-tools tree

# -----------------------------------------------------------------------------
# Application directory + ECR login helper
# -----------------------------------------------------------------------------
echo "=== Creating application directory ==="
mkdir -p /home/ubuntu/app
chown -R ubuntu:ubuntu /home/ubuntu/app

cat > /home/ubuntu/ecr-login.sh << 'ECREOF'
#!/bin/bash
# ECR login helper — run as: bash ~/ecr-login.sh
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
# Timezone
# -----------------------------------------------------------------------------
timedatectl set-timezone Asia/Seoul

# -----------------------------------------------------------------------------
# Monitoring Agent (Alloy + cAdvisor)
# Alloy: 호스트/컨테이너 메트릭 + 로그 수집 → 모니터링 서버로 push
# cAdvisor: 컨테이너 리소스 메트릭 (port 9101)
# -----------------------------------------------------------------------------
echo "=== Setting up monitoring agent ==="
mkdir -p /home/ubuntu/monitoring/alloy

# docker-compose.yml — Alloy + cAdvisor
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
      - APP_PORT=__APP_PORT__
      - INSTANCE_NAME=__INSTANCE_NAME__
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

volumes:
  alloy-data:
MONCOMPOSEEOF

# 플레이스홀더 → 실제 값 치환
sed -i "s/__MONITORING_IP__/${monitoring_ip}/g" /home/ubuntu/monitoring/docker-compose.yml
sed -i "s/__APP_PORT__/${app_port}/g" /home/ubuntu/monitoring/docker-compose.yml
sed -i "s/__INSTANCE_NAME__/${service_name}/g" /home/ubuntu/monitoring/docker-compose.yml

# Alloy config — service_name에 따라 spring(api/chat) 또는 basic(front/ai)
%{ if service_name == "api" || service_name == "chat" ~}
cat > /home/ubuntu/monitoring/alloy/config.alloy << 'ALLOYEOF'
// Grafana Alloy — Prod Spring Boot (${service_name})
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

prometheus.scrape "spring_boot" {
  targets = [
    { "__address__" = "localhost:" + sys.env("APP_PORT"), "app" = sys.env("INSTANCE_NAME") },
  ]
  metrics_path    = "/api/actuator/prometheus"
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
    regex         = "/.*(alloy|cadvisor).*"
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
%{ else ~}
cat > /home/ubuntu/monitoring/alloy/config.alloy << 'ALLOYEOF'
// Grafana Alloy — Prod Basic (${service_name})
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
    regex         = "/.*(alloy|cadvisor).*"
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
%{ endif ~}

chown -R ubuntu:ubuntu /home/ubuntu/monitoring

# 모니터링 스택 시작
echo "=== Starting monitoring stack ==="
cd /home/ubuntu/monitoring && docker compose up -d

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
echo "==========================================="
echo "   Installation Verification"
echo "==========================================="
echo "Docker: $(docker --version)"
echo "Docker Compose: $(docker compose version)"
echo "AWS CLI: $(aws --version)"
echo "SSM Agent: $(systemctl is-active snap.amazon-ssm-agent.amazon-ssm-agent.service)"
echo "Monitoring: $(docker ps --filter name=alloy --filter name=cadvisor --format '{{.Names}}: {{.Status}}')"
echo "=== User data script completed ==="
