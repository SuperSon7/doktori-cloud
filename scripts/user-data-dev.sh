#!/bin/bash
set -euxo pipefail

# ============================================================
# Doktori Dev Server - User Data (Ubuntu 24.04 ARM64)
# Docker, Docker Compose, Nginx, SSM Agent, AWS CLI
# ============================================================

export DEBIAN_FRONTEND=noninteractive

# --- System update ---
apt-get update -y
apt-get upgrade -y

# --- Essential packages ---
apt-get install -y \
  ca-certificates curl gnupg lsb-release \
  unzip jq htop net-tools \
  certbot python3-certbot-nginx

# --- Docker ---
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# --- AWS CLI v2 (ARM64) ---
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

# --- SSM Agent (should be pre-installed on Ubuntu 24.04, ensure running) ---
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service || true
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service || true

# --- Nginx ---
apt-get install -y nginx
systemctl enable nginx

# --- App directory structure ---
mkdir -p /home/ubuntu/app
chown ubuntu:ubuntu /home/ubuntu/app

# --- ECR login helper script ---
cat <<'ECRLOGIN' > /home/ubuntu/app/ecr-login.sh
#!/bin/bash
REGISTRY="250857930609.dkr.ecr.ap-northeast-2.amazonaws.com"
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin $REGISTRY
ECRLOGIN
chmod +x /home/ubuntu/app/ecr-login.sh
chown ubuntu:ubuntu /home/ubuntu/app/ecr-login.sh

# --- Cleanup ---
apt-get autoremove -y
apt-get clean

echo "=== User data setup complete ==="