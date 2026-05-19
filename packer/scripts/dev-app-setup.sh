#!/usr/bin/env bash
# =============================================================================
# Dev App AMI Setup — Docker Compose host for docker-compose.dev.yml
#
# Bakes stable host dependencies only. Runtime files such as docker-compose.yml,
# nginx.conf, alloy/config.alloy, secrets, and WireMock mappings are deployed
# after instance creation.
# =============================================================================
set -euo pipefail

DOCKER_VERSION="${DOCKER_VERSION:-5:27.4.1-1~ubuntu.22.04~jammy}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
APP_DIR="${APP_DIR:-/home/ubuntu/app}"

log() { echo "[dev-app-setup] $*"; }

wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 3; done
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 3; done
  while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 3; done
}

install_base_packages() {
  log "[1/7] base packages"
  wait_for_apt
  apt-get update -qq
  apt-get install -y -qq software-properties-common
  add-apt-repository -y universe
  apt-get update -qq
  apt-get install -y -qq \
    apt-transport-https ca-certificates curl gnupg lsb-release \
    unzip jq htop net-tools dnsutils iproute2 iptables less logrotate \
    openssl rsync ruby-full wget
}

install_docker() {
  log "[2/7] Docker CE ${DOCKER_VERSION}"
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
  log "[3/7] AWS CLI v2"
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
  log "[4/7] SSM Agent"
  if ! snap list amazon-ssm-agent >/dev/null 2>&1; then
    snap install amazon-ssm-agent --classic
  fi
  systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
  systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service
}

install_codedeploy() {
  log "[5/7] CodeDeploy Agent"
  wait_for_apt
  apt-get install -y -qq gdebi-core
  curl -fsSL "https://aws-codedeploy-${AWS_REGION}.s3.${AWS_REGION}.amazonaws.com/latest/install" -o /tmp/codedeploy-install
  chmod +x /tmp/codedeploy-install
  /tmp/codedeploy-install auto
  systemctl enable codedeploy-agent
  systemctl start codedeploy-agent
}

prepare_dev_compose_host() {
  log "[6/7] dev compose host directories and helpers"

  install -d -m 0755 -o ubuntu -g ubuntu \
    "$APP_DIR" \
    "$APP_DIR/secrets" \
    "$APP_DIR/wiremock/mappings" \
    "$APP_DIR/wiremock/files" \
    "$APP_DIR/alloy" \
    /opt/doktori/bin \
    /var/log/doktori

  install -d -m 0755 /etc/letsencrypt /var/www/certbot

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

  cat > /opt/doktori/bin/dev-compose.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$APP_DIR"
exec docker compose -f docker-compose.dev.yml "\$@"
EOF
  chmod 0755 /opt/doktori/bin/dev-compose.sh
  ln -sf /opt/doktori/bin/dev-compose.sh /usr/local/bin/doktori-dev-compose

  cat > /etc/sysctl.d/99-doktori-dev-compose.conf <<'EOF'
vm.max_map_count = 262144
fs.file-max = 1048576
EOF
  sysctl --system >/dev/null
}

verify() {
  log "[7/7] verify"
  docker --version
  docker compose version
  aws --version
  systemctl is-active --quiet docker
  systemctl is-active --quiet snap.amazon-ssm-agent.amazon-ssm-agent.service
  systemctl is-active --quiet codedeploy-agent
}

cleanup() {
  wait_for_apt
  apt-get autoremove -y -qq
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  cloud-init clean --logs 2>/dev/null || true
}

main() {
  log "Dev App AMI Build: Docker ${DOCKER_VERSION}"
  install_base_packages
  install_docker
  install_awscli
  install_ssm_agent
  install_codedeploy
  prepare_dev_compose_host
  verify
  cleanup
  log "done"
}

main
