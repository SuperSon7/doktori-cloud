#!/bin/bash
set -e

# -----------------------------------------------------------------------------
# User Data Script for Monitoring Server (Ubuntu 24.04)
# Project: ${project_name}
# Architecture: ${architecture}
#
# 설치 항목: Docker, AWS CLI v2, SSM Agent, 기본 도구
# 모니터링 스택(Prometheus/Loki/Grafana)은 docker-compose로 별도 배포
# -----------------------------------------------------------------------------

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Starting monitoring server user data ==="
echo "Project: ${project_name}"
echo "Architecture: ${architecture}"

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
# Install Docker (CE + Compose plugin)
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
# Install AWS CLI v2 (아키텍처별 분기)
# -----------------------------------------------------------------------------
echo "=== Installing AWS CLI v2 ==="
if [ "${architecture}" = "arm64" ]; then
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
else
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
fi
apt-get install -y unzip
unzip -q awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

# -----------------------------------------------------------------------------
# SSM Agent (Ubuntu 24.04 snap 기반)
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
# Monitoring directory structure
# -----------------------------------------------------------------------------
echo "=== Creating monitoring directory ==="
mkdir -p /home/ubuntu/monitoring
chown -R ubuntu:ubuntu /home/ubuntu/monitoring

# -----------------------------------------------------------------------------
# Swap (2GB)
# -----------------------------------------------------------------------------
echo "=== Configuring swap ==="
dd if=/dev/zero of=/swapfile bs=128M count=16
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile swap swap defaults 0 0' >> /etc/fstab

# -----------------------------------------------------------------------------
# Timezone
# -----------------------------------------------------------------------------
timedatectl set-timezone Asia/Seoul

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
echo "==========================================="
echo "   Installation Verification"
echo "==========================================="
echo "Docker:         $(docker --version)"
echo "Docker Compose: $(docker compose version)"
echo "AWS CLI:        $(aws --version)"
echo "SSM Agent:      $(systemctl is-active snap.amazon-ssm-agent.amazon-ssm-agent.service)"
echo "Architecture:   $(uname -m)"
echo ""
echo "=== Next Steps ==="
echo "1. scp Cloud/monitoring/ → /home/ubuntu/monitoring/"
echo "2. cp .env.example .env && vi .env"
echo "3. docker compose up -d"
echo "=== User data script completed ==="
