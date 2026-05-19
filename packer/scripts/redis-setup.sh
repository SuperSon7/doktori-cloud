#!/usr/bin/env bash
# =============================================================================
# Redis AMI Setup — Redis server + Grafana Alloy + AWS CLI + SSM Agent
#
# Packer provisioner로 실행됨
# 환경변수: REDIS_VERSION (메이저.마이너, e.g. "7.2")
# =============================================================================
set -euo pipefail

REDIS_VERSION="${REDIS_VERSION:-7.2}"
ALLOY_VERSION="${ALLOY_VERSION:-1.15.0}"

log() { echo "[redis-setup] $*"; }

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

install_redis() {
  log "[2/6] Redis ${REDIS_VERSION} 설치 (packages.redis.io)"
  wait_for_apt

  # GPG 키 (멱등: 이미 있으면 스킵)
  if [ ! -f /etc/apt/keyrings/redis.gpg ]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://packages.redis.io/gpg \
      | gpg --dearmor --batch --yes -o /etc/apt/keyrings/redis.gpg
    chmod a+r /etc/apt/keyrings/redis.gpg
  fi

  # apt source (멱등)
  if [ ! -f /etc/apt/sources.list.d/redis.list ]; then
    echo "deb [signed-by=/etc/apt/keyrings/redis.gpg] https://packages.redis.io/deb $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
      > /etc/apt/sources.list.d/redis.list
  fi

  wait_for_apt
  apt-get update -qq

  # 공식 APT 가이드 기준으로 redis/redis-server/redis-tools/redis-sentinel을
  # 동일 버전으로 함께 설치한다. redis-server만 단독 핀하면 의존성 해석이
  # 어긋나 held broken packages가 날 수 있다.
  VERSION_RE="${REDIS_VERSION//./\\.}"
  AVAILABLE=$(apt-cache madison redis 2>/dev/null \
    | awk '{print $3}' \
    | grep -E "^([0-9]+:)?${VERSION_RE}([[:punct:]]|$)" \
    | head -1 || true)

  if [ -n "$AVAILABLE" ]; then
    apt-get install -y -qq \
      "redis=${AVAILABLE}" \
      "redis-server=${AVAILABLE}" \
      "redis-tools=${AVAILABLE}" \
      "redis-sentinel=${AVAILABLE}"
    apt-mark hold redis redis-server redis-tools redis-sentinel
  else
    log "요청 Redis 버전(${REDIS_VERSION}.*) 없음"
    apt-cache madison redis 2>/dev/null | awk '{print "  available: " $3}' | head -10 || true
    exit 1
  fi

  # bind: 127.0.0.1 → 0.0.0.0 (접근 제어는 SG에서)
  # sed는 멱등 — 이미 0.0.0.0이면 패턴 불일치로 무변환
  sed -i 's/^bind 127\.0\.0\.1 -::1$/bind 0.0.0.0/' /etc/redis/redis.conf
  sed -i 's/^protected-mode yes$/protected-mode no/' /etc/redis/redis.conf

  systemctl enable redis-server
  systemctl start redis-server
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
  systemctl stop redis-server || true
  rm -rf /var/lib/redis/*
  install -m 0750 -o redis -g redis -d /var/lib/redis
  wait_for_apt
  apt-get autoremove -y -qq
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  cloud-init clean --logs 2>/dev/null || true
}

main() {
  echo "============================================="
  echo " Redis AMI Build: ${REDIS_VERSION}"
  echo "============================================="

  install_base
  install_redis
  install_awscli
  install_ssm_agent
  install_alloy
  cleanup

  echo ""
  echo "============================================="
  echo " Redis AMI Build 완료"
  echo "============================================="
  echo "  redis-server : $(redis-server --version)"
  echo "  alloy        : $(alloy --version 2>&1 | head -1)"
  echo "  aws cli      : $(aws --version 2>&1 | head -1)"
  echo "  ssm agent    : $(snap list amazon-ssm-agent 2>/dev/null | tail -1 | awk '{print $2}')"
  echo "============================================="
}

main
