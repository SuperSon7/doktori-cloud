#!/usr/bin/env bash
# =============================================================================
# Dev AI AMI Setup — Docker host for AI service, weekly batch, and Qdrant
# =============================================================================
set -euo pipefail

DOCKER_VERSION="${DOCKER_VERSION:-5:27.4.1-1~ubuntu.22.04~jammy}"

log() { echo "[dev-ai-setup] $*"; }

wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 3; done
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 3; done
  while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 3; done
}

install_base_packages() {
  log "[1/6] base packages"
  wait_for_apt
  apt-get update -qq
  apt-get install -y -qq software-properties-common
  add-apt-repository -y universe
  apt-get update -qq
  apt-get install -y -qq \
    apt-transport-https ca-certificates curl gnupg lsb-release \
    unzip jq htop net-tools dnsutils iproute2 less logrotate wget
}

install_docker() {
  log "[2/6] Docker CE ${DOCKER_VERSION}"
  wait_for_apt

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor --batch --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

  wait_for_apt
  apt-get update -qq
  if ! apt-cache show "docker-ce=${DOCKER_VERSION}" >/dev/null 2>&1; then
    log "requested Docker version unavailable: ${DOCKER_VERSION}"
    exit 1
  fi

  apt-get install -y -qq \
    "docker-ce=${DOCKER_VERSION}" \
    "docker-ce-cli=${DOCKER_VERSION}" \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  apt-mark hold docker-ce docker-ce-cli
  systemctl enable docker
  systemctl start docker
  usermod -aG docker ubuntu
}

install_awscli() {
  log "[3/6] AWS CLI v2"
  local arch url
  arch=$(uname -m)
  if [ "$arch" = "aarch64" ]; then
    url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
  else
    url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
  fi

  curl -fsSL "$url" -o /tmp/awscliv2.zip
  cd /tmp && unzip -qo awscliv2.zip && ./aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
}

install_ssm_agent() {
  log "[4/6] SSM Agent"
  if ! snap list amazon-ssm-agent >/dev/null 2>&1; then
    snap install amazon-ssm-agent --classic
  fi
  systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
  systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service
}

prepare_ai_host() {
  log "[5/6] AI host directories and helpers"

  install -d -m 0755 -o ubuntu -g ubuntu \
    /home/ubuntu/app \
    /opt/doktori \
    /opt/doktori/bin \
    /opt/qdrant \
    /var/log/doktori

  cat > /opt/doktori/bin/ecr-login.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
REGION="${AWS_REGION:-ap-northeast-2}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
EOF
  chmod 0755 /opt/doktori/bin/ecr-login.sh
  ln -sf /opt/doktori/bin/ecr-login.sh /usr/local/bin/doktori-ecr-login
}

verify() {
  log "[6/6] verify"
  docker --version
  docker compose version
  aws --version
  systemctl is-active --quiet docker
  systemctl is-active --quiet snap.amazon-ssm-agent.amazon-ssm-agent.service
}

cleanup() {
  wait_for_apt
  apt-get autoremove -y -qq
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  cloud-init clean --logs 2>/dev/null || true
}

main() {
  log "Dev AI AMI Build: Docker ${DOCKER_VERSION}"
  install_base_packages
  install_docker
  install_awscli
  install_ssm_agent
  prepare_ai_host
  verify
  cleanup
  log "done"
}

main "$@"
