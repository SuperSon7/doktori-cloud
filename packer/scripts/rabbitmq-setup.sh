#!/usr/bin/env bash
# =============================================================================
# RabbitMQ AMI Setup — Erlang + RabbitMQ + management/prometheus plugins + Alloy + AWS CLI + SSM
#
# Packer provisioner로 실행됨
# 환경변수: RABBITMQ_VERSION (e.g. "3.13"), ERLANG_VERSION (메이저, e.g. "26")
#
# 공식 권장 방식:
# - arm64 Erlang 26: Team RabbitMQ Launchpad PPA
# - RabbitMQ server: Team RabbitMQ apt repository
# =============================================================================
set -Eeuo pipefail

RABBITMQ_VERSION="${RABBITMQ_VERSION:-3.13}"
ERLANG_VERSION="${ERLANG_VERSION:-26}"
ALLOY_VERSION="${ALLOY_VERSION:-1.15.0}"

log() { echo "[rabbitmq-setup] $*"; }

error_handler() {
  local rc=$?
  log "ERROR line ${BASH_LINENO[0]}: ${BASH_COMMAND} (exit ${rc})"
  if systemctl list-unit-files rabbitmq-server.service >/dev/null 2>&1; then
    systemctl status rabbitmq-server --no-pager || true
    journalctl -u rabbitmq-server -n 50 --no-pager || true
  fi
  exit "$rc"
}

trap error_handler ERR

wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 3; done
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 3; done
  while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 3; done
}

install_base() {
  log "[1/7] base 패키지 설치"
  wait_for_apt
  apt-get update -qq
  apt-get install -y -qq software-properties-common
  add-apt-repository -y universe
  apt-get update -qq
  apt-get install -y -qq \
    ca-certificates curl gnupg apt-transport-https \
    unzip jq
}

install_erlang() {
  log "[2/7] Erlang ${ERLANG_VERSION} 설치 (Launchpad PPA for arm64)"
  wait_for_apt

  local codename arch erlang_ppa
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  arch=$(dpkg --print-architecture)

  case "$ERLANG_VERSION" in
    26) erlang_ppa="rabbitmq-erlang-26" ;;
    27) erlang_ppa="rabbitmq-erlang-27" ;;
    *)
      log "지원하지 않는 Erlang major version: ${ERLANG_VERSION} (Launchpad PPA 매핑 없음)"
      exit 1
      ;;
  esac

  # Launchpad PPA signing key (멱등)
  if [ ! -f "/etc/apt/keyrings/${erlang_ppa}.gpg" ]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -1sLf "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xf77f1eda57ebb1cc" \
      | gpg --dearmor --batch --yes -o "/etc/apt/keyrings/${erlang_ppa}.gpg"
    chmod a+r "/etc/apt/keyrings/${erlang_ppa}.gpg"
  fi

  # apt source (멱등)
  if [ ! -f /etc/apt/sources.list.d/rabbitmq-erlang.list ]; then
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/${erlang_ppa}.gpg] https://ppa.launchpadcontent.net/rabbitmq/${erlang_ppa}/ubuntu ${codename} main" \
      > /etc/apt/sources.list.d/rabbitmq-erlang.list
  fi

  wait_for_apt
  apt-get update -qq

  VERSION_RE="${ERLANG_VERSION//./\\.}"
  AVAILABLE=$(apt-cache madison erlang-base 2>/dev/null \
    | awk '{print $3}' \
    | grep -E "^([0-9]+:)?${VERSION_RE}([[:punct:]]|$)" \
    | head -1 || true)

  if [ -n "$AVAILABLE" ]; then
    apt-get install -y -qq \
      "erlang-base=${AVAILABLE}" \
      "erlang-asn1=${AVAILABLE}" \
      "erlang-crypto=${AVAILABLE}" \
      "erlang-eldap=${AVAILABLE}" \
      "erlang-ftp=${AVAILABLE}" \
      "erlang-inets=${AVAILABLE}" \
      "erlang-mnesia=${AVAILABLE}" \
      "erlang-os-mon=${AVAILABLE}" \
      "erlang-parsetools=${AVAILABLE}" \
      "erlang-public-key=${AVAILABLE}" \
      "erlang-runtime-tools=${AVAILABLE}" \
      "erlang-snmp=${AVAILABLE}" \
      "erlang-ssl=${AVAILABLE}" \
      "erlang-syntax-tools=${AVAILABLE}" \
      "erlang-tftp=${AVAILABLE}" \
      "erlang-tools=${AVAILABLE}" \
      "erlang-xmerl=${AVAILABLE}"
    apt-mark hold erlang-base erlang-crypto erlang-ssl
  else
    log "요청 Erlang 버전(${ERLANG_VERSION}) 없음"
    apt-cache madison erlang-base 2>/dev/null | awk '{print "  available: " $3}' | head -10 || true
    exit 1
  fi
}

install_rabbitmq() {
  log "[3/7] RabbitMQ ${RABBITMQ_VERSION} 설치 (deb1/deb2.rabbitmq.com)"
  wait_for_apt

  # GPG 키 (멱등)
  if [ ! -f /etc/apt/keyrings/rabbitmq.gpg ]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -1sLf "https://keys.openpgp.org/vks/v1/by-fingerprint/0A9AF2115F4687BD29803A206B73A36E6026DFCA" \
      | gpg --dearmor --batch --yes -o /etc/apt/keyrings/rabbitmq.gpg
    chmod a+r /etc/apt/keyrings/rabbitmq.gpg
  fi

  # apt source (멱등)
  if [ ! -f /etc/apt/sources.list.d/rabbitmq.list ]; then
    cat > /etc/apt/sources.list.d/rabbitmq.list <<EOF
deb [signed-by=/etc/apt/keyrings/rabbitmq.gpg] https://deb1.rabbitmq.com/rabbitmq-server/ubuntu/$(. /etc/os-release && echo "$VERSION_CODENAME") $(. /etc/os-release && echo "$VERSION_CODENAME") main
deb [signed-by=/etc/apt/keyrings/rabbitmq.gpg] https://deb2.rabbitmq.com/rabbitmq-server/ubuntu/$(. /etc/os-release && echo "$VERSION_CODENAME") $(. /etc/os-release && echo "$VERSION_CODENAME") main
EOF
  fi

  wait_for_apt
  apt-get update -qq

  VERSION_RE="${RABBITMQ_VERSION//./\\.}"
  AVAILABLE=$(apt-cache madison rabbitmq-server 2>/dev/null \
    | awk '{print $3}' \
    | grep -E "^([0-9]+:)?${VERSION_RE}([[:punct:]]|$)" \
    | head -1 || true)

  if [ -n "$AVAILABLE" ]; then
    apt-get install -y -qq "rabbitmq-server=${AVAILABLE}"
    apt-mark hold rabbitmq-server
  else
    log "요청 RabbitMQ 버전(${RABBITMQ_VERSION}) 없음"
    apt-cache madison rabbitmq-server 2>/dev/null | awk '{print "  available: " $3}' | head -10 || true
    exit 1
  fi

  # 패키지 설치 직후 서비스가 아직 실행 중이 아닐 수 있으므로 offline 모드로
  # 플러그인 활성화 상태만 기록하고, 실제 기동은 systemd start에서 맡긴다.
  rabbitmq-plugins enable --offline rabbitmq_management rabbitmq_prometheus

  systemctl enable rabbitmq-server
  systemctl start rabbitmq-server
}

install_awscli() {
  log "[4/7] AWS CLI v2 설치"
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
  log "[5/7] SSM Agent 설치"
  if snap list amazon-ssm-agent >/dev/null 2>&1; then
    log "SSM Agent 이미 설치됨 — 스킵"
    return
  fi

  snap install amazon-ssm-agent --classic
  systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
  systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service
}

install_alloy() {
  log "[6/7] Grafana Alloy 설치"
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
  log "[7/7] 정리"
  systemctl stop rabbitmq-server || true
  rm -rf /var/lib/rabbitmq/mnesia
  rm -f /var/lib/rabbitmq/.erlang.cookie
  install -m 0750 -o rabbitmq -g rabbitmq -d /var/lib/rabbitmq
  wait_for_apt
  apt-get autoremove -y -qq
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  cloud-init clean --logs 2>/dev/null || true
}

main() {
  echo "============================================="
  echo " RabbitMQ AMI Build: ${RABBITMQ_VERSION} (Erlang ${ERLANG_VERSION})"
  echo "============================================="

  install_base
  install_erlang
  install_rabbitmq
  install_awscli
  install_ssm_agent
  install_alloy
  cleanup

  echo ""
  echo "============================================="
  echo " RabbitMQ AMI Build 완료"
  echo "============================================="
  echo "  rabbitmq     : $(rabbitmqctl version 2>/dev/null || echo 'n/a')"
  echo "  erlang       : $(erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell 2>/dev/null || echo 'n/a')"
  echo "  alloy        : $(alloy --version 2>&1 | head -1)"
  echo "  aws cli      : $(aws --version 2>&1 | head -1)"
  echo "  ssm agent    : $(snap list amazon-ssm-agent 2>/dev/null | tail -1 | awk '{print $2}')"
  echo "============================================="
}

main
