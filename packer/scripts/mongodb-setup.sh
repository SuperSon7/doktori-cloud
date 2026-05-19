#!/usr/bin/env bash
# =============================================================================
# MongoDB AMI Setup — MongoDB server + Grafana Alloy + AWS CLI + SSM Agent
#
# Packer provisioner로 실행됨
# 환경변수: MONGODB_VERSION (메이저.마이너, e.g. "7.0")
# =============================================================================
set -euo pipefail

MONGODB_VERSION="${MONGODB_VERSION:-7.0}"
ALLOY_VERSION="${ALLOY_VERSION:-1.15.0}"

log() { echo "[mongodb-setup] $*"; }

wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 3; done
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 3; done
  while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 3; done
}

install_base() {
  log "[1/6] base 패키지 설치"
  wait_for_apt
  apt-get update -qq
  apt-get install -y -qq software-properties-common
  add-apt-repository -y universe
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg unzip jq apt-transport-https
}

install_mongodb() {
  log "[2/6] MongoDB ${MONGODB_VERSION} 설치 (repo.mongodb.org)"
  wait_for_apt

  # GPG 키 (멱등)
  if [ ! -f /etc/apt/keyrings/mongodb.gpg ]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGODB_VERSION}.asc" \
      | gpg --dearmor --batch --yes -o /etc/apt/keyrings/mongodb.gpg
    chmod a+r /etc/apt/keyrings/mongodb.gpg
  fi

  # apt source (멱등)
  if [ ! -f /etc/apt/sources.list.d/mongodb-org.list ]; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/mongodb.gpg] https://repo.mongodb.org/apt/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME")/mongodb-org/${MONGODB_VERSION} multiverse" \
      > /etc/apt/sources.list.d/mongodb-org.list
  fi

  wait_for_apt
  apt-get update -qq
  apt-get install -y -qq mongodb-org
  apt-mark hold mongodb-org mongodb-org-database mongodb-org-server \
    mongodb-org-mongos mongodb-org-tools

  # bindIp는 VPC 내부 앱 서브넷에서 접근할 수 있게 열고, Mongo 인증은 항상 활성화한다.
  if grep -q 'bindIp: 127\.0\.0\.1' /etc/mongod.conf 2>/dev/null; then
    sed -i 's/bindIp: 127\.0\.0\.1/bindIp: 0.0.0.0/' /etc/mongod.conf
  fi
  if grep -q '^security:' /etc/mongod.conf 2>/dev/null; then
    if grep -q '^[[:space:]]*authorization:' /etc/mongod.conf 2>/dev/null; then
      sed -i 's/^[[:space:]]*authorization:.*/  authorization: enabled/' /etc/mongod.conf
    else
      sed -i '/^security:/a\  authorization: enabled' /etc/mongod.conf
    fi
  else
    printf '\nsecurity:\n  authorization: enabled\n' >>/etc/mongod.conf
  fi

  systemctl enable mongod
  systemctl start mongod
}

install_awscli() {
  log "[3/6] AWS CLI v2 설치"
  if aws --version >/dev/null 2>&1; then
    log "AWS CLI 이미 설치됨 — 스킵"
    return
  fi

  local arch
  arch=$(uname -m)
  local url
  if [ "$arch" = "aarch64" ]; then
    url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
  else
    url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
  fi

  curl -fsSL "$url" -o /tmp/awscliv2.zip
  cd /tmp && unzip -qo awscliv2.zip && ./aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip
}

install_ssm_agent() {
  log "[4/6] SSM Agent 설치"
  if snap list amazon-ssm-agent >/dev/null 2>&1; then
    log "SSM Agent 이미 설치됨 — 스킵"
    return
  fi

  snap install amazon-ssm-agent --classic
  systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
  systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service
}

install_alloy() {
  log "[5/6] Grafana Alloy 설치"
  wait_for_apt

  if command -v alloy >/dev/null 2>&1; then
    log "Grafana Alloy 이미 설치됨 — 스킵"
    return
  fi

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg-full.key -o /etc/apt/keyrings/grafana.asc
  chmod 0644 /etc/apt/keyrings/grafana.asc
  echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list

  wait_for_apt
  apt-get update -qq
  AVAILABLE=$(apt-cache madison alloy 2>/dev/null \
    | awk '{print $3}' \
    | grep "^${ALLOY_VERSION}" \
    | head -1 || true)

  if [ -n "$AVAILABLE" ]; then
    apt-get install -y -qq "alloy=${AVAILABLE}"
    apt-mark hold alloy
  else
    log "요청 Alloy 버전(${ALLOY_VERSION}) 없음"
    exit 1
  fi
  systemctl enable alloy
  systemctl stop alloy || true
}

cleanup() {
  log "[6/6] 정리"
  systemctl stop mongod || true
  rm -rf /var/lib/mongodb/*
  install -m 0755 -o mongodb -g mongodb -d /var/lib/mongodb
  wait_for_apt
  apt-get autoremove -y -qq
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  cloud-init clean --logs 2>/dev/null || true
}

main() {
  echo "============================================="
  echo " MongoDB AMI Build: ${MONGODB_VERSION}"
  echo "============================================="

  install_base
  install_mongodb
  install_awscli
  install_ssm_agent
  install_alloy
  cleanup

  echo ""
  echo "============================================="
  echo " MongoDB AMI Build 완료"
  echo "============================================="
  echo "  mongod       : $(mongod --version | head -1)"
  echo "  alloy        : $(alloy --version 2>&1 | head -1)"
  echo "  aws cli      : $(aws --version 2>&1 | head -1)"
  echo "  ssm agent    : $(snap list amazon-ssm-agent 2>/dev/null | tail -1 | awk '{print $2}')"
  echo "============================================="
}

main
