#!/bin/bash
set -e

# -----------------------------------------------------------------------------
# User Data Script for Dev App (Ubuntu 22.04)
# Project: ${project_name}
# Environment: ${environment}
# Runs docker-compose with all services
# -----------------------------------------------------------------------------

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Starting user data script ==="
echo "Project: ${project_name}"
echo "Environment: ${environment}"

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
# Install AWS CLI v2
# -----------------------------------------------------------------------------
echo "=== Installing AWS CLI v2 ==="
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
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
# Application directory
# -----------------------------------------------------------------------------
echo "=== Creating application directory ==="
mkdir -p /home/ubuntu/app
chown -R ubuntu:ubuntu /home/ubuntu/app

# -----------------------------------------------------------------------------
# Swap (2GB for t3.small)
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
echo "Docker: $(docker --version)"
echo "Docker Compose: $(docker compose version)"
echo "AWS CLI: $(aws --version)"
echo "SSM Agent: $(systemctl is-active snap.amazon-ssm-agent.amazon-ssm-agent.service)"
echo "=== User data script completed ==="
