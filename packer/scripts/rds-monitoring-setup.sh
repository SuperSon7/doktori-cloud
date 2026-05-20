#!/usr/bin/env bash
# =============================================================================
# RDS Monitoring AMI Setup — Prometheus mysqld_exporter + AWS CLI + SSM Agent
#
# Packer provisioner로 실행됨
# 환경변수: MYSQLD_EXPORTER_VERSION (v prefix 없음, e.g. "0.15.1")
#
# 자격증명(DSN)은 AMI에 굽지 않음.
# 인스턴스 부팅 시 user_data가 SSM Parameter Store에서 읽어
# /etc/mysqld_exporter.cnf 파일에 MySQL client 설정을 기록함.
# =============================================================================
set -euo pipefail

MYSQLD_EXPORTER_VERSION="${MYSQLD_EXPORTER_VERSION:-0.15.1}"
INSTALL_DIR="/usr/local/bin"
SERVICE_USER="mysqld_exporter"

log() { echo "[rds-monitoring-setup] $*"; }

wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 3; done
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 3; done
  while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 3; done
}

install_base() {
  log "[1/5] base 패키지 설치"
  wait_for_apt
  apt-get update -qq
  apt-get install -y -qq software-properties-common
  add-apt-repository -y universe
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl unzip jq
}

install_mysqld_exporter() {
  log "[2/5] mysqld_exporter ${MYSQLD_EXPORTER_VERSION} 설치"

  # 멱등: 동일 버전 이미 설치되어 있으면 스킵
  if [ -f "${INSTALL_DIR}/mysqld_exporter" ]; then
    INSTALLED=$("${INSTALL_DIR}/mysqld_exporter" --version 2>&1 | grep -oP 'version \K[0-9.]+' || echo "")
    if [ "$INSTALLED" = "$MYSQLD_EXPORTER_VERSION" ]; then
      log "mysqld_exporter ${MYSQLD_EXPORTER_VERSION} 이미 설치됨 — 스킵"
      return
    fi
  fi

  local arch
  arch=$(uname -m)
  local go_arch
  if [ "$arch" = "aarch64" ]; then
    go_arch="arm64"
  else
    go_arch="amd64"
  fi

  local tarball="mysqld_exporter-${MYSQLD_EXPORTER_VERSION}.linux-${go_arch}.tar.gz"
  local url="https://github.com/prometheus/mysqld_exporter/releases/download/v${MYSQLD_EXPORTER_VERSION}/${tarball}"

  log "  다운로드: ${url}"
  curl -fsSL "$url" -o "/tmp/${tarball}"

  # checksum 검증 (sha256sums 파일 사용)
  local sha256_url="https://github.com/prometheus/mysqld_exporter/releases/download/v${MYSQLD_EXPORTER_VERSION}/sha256sums.txt"
  curl -fsSL "$sha256_url" -o /tmp/mysqld_exporter_sha256sums.txt
  # tarball에 해당하는 라인만 검증
  (
    cd /tmp
    grep -F "$tarball" mysqld_exporter_sha256sums.txt | sha256sum -c -
  )
  rm -f /tmp/mysqld_exporter_sha256sums.txt

  tar -xzf "/tmp/${tarball}" -C /tmp
  install -m 0755 "/tmp/mysqld_exporter-${MYSQLD_EXPORTER_VERSION}.linux-${go_arch}/mysqld_exporter" "${INSTALL_DIR}/mysqld_exporter"
  rm -rf "/tmp/${tarball}" "/tmp/mysqld_exporter-${MYSQLD_EXPORTER_VERSION}.linux-${go_arch}"

  log "  설치 완료: $(${INSTALL_DIR}/mysqld_exporter --version 2>&1 | head -1)"
}

configure_service() {
  log "[3/5] systemd service 설정"

  # 전용 유저 생성 (멱등: 이미 있으면 스킵)
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /bin/false "$SERVICE_USER"
  fi

  # mysqld_exporter 0.15+ no longer supports DATA_SOURCE_NAME.
  # 실제 접속 정보는 인스턴스 부팅 시 user_data가 SSM에서 읽어 기록한다.
  if [ ! -f /etc/mysqld_exporter.cnf ]; then
    cat > /etc/mysqld_exporter.cnf <<'EOF'
# user_data 스크립트가 인스턴스 부팅 시 SSM Parameter Store에서 읽어 채움
[client]
user =
EOF
    chmod 640 /etc/mysqld_exporter.cnf
    chown root:"$SERVICE_USER" /etc/mysqld_exporter.cnf
  fi

  # systemd unit 파일 생성 (멱등: 같은 내용이면 재생성해도 무해)
  cat > /etc/systemd/system/mysqld_exporter.service <<EOF
[Unit]
Description=Prometheus MySQL Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${INSTALL_DIR}/mysqld_exporter \
  --config.my-cnf=/etc/mysqld_exporter.cnf \
  --web.listen-address=:9104 \
  --collect.info_schema.innodb_metrics \
  --collect.info_schema.processlist \
  --collect.global_status \
  --collect.global_variables \
  --no-collect.slave_status

Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl disable mysqld_exporter >/dev/null 2>&1 || true
  # 서비스는 DB 접속 설정 없이 시작 불가 — user_data가 설정 파일을 쓴 뒤 enable/start 한다.
}

install_awscli() {
  log "[4/5] AWS CLI v2 설치"
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
  log "[5/5] SSM Agent 설치"
  if snap list amazon-ssm-agent >/dev/null 2>&1; then
    log "SSM Agent 이미 설치됨 — 스킵"
    return
  fi

  snap install amazon-ssm-agent --classic
  systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
  systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service
}

cleanup() {
  wait_for_apt
  apt-get autoremove -y -qq
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  cloud-init clean --logs 2>/dev/null || true
}

main() {
  echo "============================================="
  echo " RDS Monitoring AMI Build: mysqld_exporter ${MYSQLD_EXPORTER_VERSION}"
  echo "============================================="

  install_base
  install_mysqld_exporter
  configure_service
  install_awscli
  install_ssm_agent
  cleanup

  echo ""
  echo "============================================="
  echo " RDS Monitoring AMI Build 완료"
  echo "============================================="
  echo "  mysqld_exporter : $(${INSTALL_DIR}/mysqld_exporter --version 2>&1 | head -1)"
  echo "  service unit    : $(systemctl is-enabled mysqld_exporter)"
  echo "  aws cli         : $(aws --version 2>&1 | head -1)"
  echo "  ssm agent       : $(snap list amazon-ssm-agent 2>/dev/null | tail -1 | awk '{print $2}')"
  echo "============================================="
}

main
