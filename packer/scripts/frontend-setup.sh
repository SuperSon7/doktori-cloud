#!/usr/bin/env bash
# =============================================================================
# Frontend AMI Setup — Docker CE + Compose + ECR login + AWS CLI + SSM + CodeDeploy
#
# Packer provisioner로 실행됨
# 환경변수: DOCKER_VERSION
# =============================================================================
set -euo pipefail

DOCKER_VERSION="${DOCKER_VERSION:-5:27.4.1-1~ubuntu.22.04~jammy}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

echo "============================================="
echo " Frontend AMI Build"
echo " Docker: ${DOCKER_VERSION}"
echo "============================================="

log() {
  echo "[frontend-setup] $1"
}

wait_for_apt() {
  log "Waiting for apt/dpkg locks"
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 3; done
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 3; done
  while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 3; done
}

install_base_packages() {
  log "[1/7] Installing base packages"
  wait_for_apt
  apt-get update -qq
  apt-get install -y -qq \
    ca-certificates curl gnupg \
    unzip jq htop net-tools \
    ruby-full wget gdebi-core
}

install_docker() {
  log "[2/7] Installing Docker CE ${DOCKER_VERSION}"
  wait_for_apt

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --batch --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

  wait_for_apt
  apt-get update -qq
  if apt-cache show "docker-ce=${DOCKER_VERSION}" > /dev/null 2>&1; then
    apt-get install -y -qq \
      "docker-ce=${DOCKER_VERSION}" \
      "docker-ce-cli=${DOCKER_VERSION}" \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin
  else
    log "Requested Docker version unavailable, installing latest"
    apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  fi

  apt-mark hold docker-ce docker-ce-cli
  systemctl enable docker
  systemctl start docker
  usermod -aG docker ubuntu
}

install_awscli() {
  log "[3/7] Installing AWS CLI v2"
  local arch
  arch=$(uname -m)

  if [ "$arch" = "aarch64" ]; then
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
  else
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  fi

  cd /tmp
  unzip -qo awscliv2.zip
  ./aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
}

install_ssm_agent() {
  log "[4/7] Installing SSM agent"
  snap install amazon-ssm-agent --classic
  systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
  systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service
}

install_codedeploy() {
  log "[5/7] Installing CodeDeploy agent"
  wait_for_apt
  apt-get install -y -qq gdebi-core

  curl -fsSL "https://aws-codedeploy-${AWS_REGION}.s3.${AWS_REGION}.amazonaws.com/latest/install" -o /tmp/codedeploy-install
  chmod +x /tmp/codedeploy-install
  /tmp/codedeploy-install auto
  systemctl enable codedeploy-agent
  systemctl start codedeploy-agent
}

configure_ecr_login() {
  log "[6/7] Configuring ECR helper"
  mkdir -p /home/ubuntu/app
  cat <<'ECRLOGIN' > /home/ubuntu/app/ecr-login.sh
#!/bin/bash
REGION="${AWS_DEFAULT_REGION:-ap-northeast-2}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
ECRLOGIN
  chmod +x /home/ubuntu/app/ecr-login.sh
  chown -R ubuntu:ubuntu /home/ubuntu/app
}

verify_services() {
  log "[7/7] Verifying services"
  systemctl is-active --quiet docker
  systemctl is-active --quiet codedeploy-agent

  echo ""
  echo "============================================="
  echo " Frontend AMI Build 완료"
  echo "============================================="
  echo "  docker        : $(docker --version)"
  echo "  compose       : $(docker compose version)"
  echo "  aws cli       : $(aws --version 2>&1 | head -1)"
  echo "  ssm agent     : $(snap list amazon-ssm-agent 2>/dev/null | tail -1 | awk '{print $2}')"
  echo "  codedeploy    : $(systemctl is-active codedeploy-agent 2>/dev/null || true)"
  echo "============================================="
}

cleanup() {
  log "Cleaning up"
  wait_for_apt
  apt-get autoremove -y -qq
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  cloud-init clean --logs 2>/dev/null || true
}

main() {
  install_base_packages
  install_docker
  install_awscli
  install_ssm_agent
  install_codedeploy
  configure_ecr_login
  verify_services
  cleanup
}

main
