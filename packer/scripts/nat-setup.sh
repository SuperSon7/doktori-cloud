#!/usr/bin/env bash
# =============================================================================
# NAT AMI Setup — persistent MASQUERADE + WireGuard tools + AWS CLI + SSM Agent
#
# Packer provisioner로 실행됨
# NAT 역할 자체는 AMI에 굽고, Terraform user_data는 필요 시 런타임 override만 담당한다.
# =============================================================================
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-2}"

log() { echo "[nat-setup] $*"; }

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
  apt-get install -y -qq \
    ca-certificates curl unzip jq \
    iptables-persistent netfilter-persistent wireguard
}

configure_sysctl() {
  log "[2/6] IP forwarding 설정"
  cat > /etc/sysctl.d/99-doktori-nat.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
  sysctl --system >/dev/null
}

install_nat_bootstrap() {
  log "[3/6] NAT boot service 설치"

  install -m 0755 -d /usr/local/sbin
  cat > /usr/local/sbin/doktori-nat-ensure.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

DEFAULT_IF=$(ip route get 1.1.1.1 | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')

if [ -z "${DEFAULT_IF}" ]; then
  echo "could not determine default egress interface" >&2
  exit 1
fi

iptables -t nat -N DOKTORI_NAT 2>/dev/null || true
iptables -t nat -F DOKTORI_NAT
iptables -t nat -A DOKTORI_NAT -o "${DEFAULT_IF}" -j MASQUERADE
iptables -t nat -C POSTROUTING -j DOKTORI_NAT 2>/dev/null || \
  iptables -t nat -A POSTROUTING -j DOKTORI_NAT

iptables-save > /etc/iptables/rules.v4
EOF
  chmod 0755 /usr/local/sbin/doktori-nat-ensure.sh

  cat > /etc/systemd/system/doktori-nat-ensure.service <<'EOF'
[Unit]
Description=Ensure NAT iptables MASQUERADE rule is present
Wants=network-online.target
After=network-online.target netfilter-persistent.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/doktori-nat-ensure.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable netfilter-persistent
  systemctl enable doktori-nat-ensure.service
  /usr/local/sbin/doktori-nat-ensure.sh
}

install_awscli() {
  log "[4/6] AWS CLI v2 설치"
  if aws --version >/dev/null 2>&1; then
    log "AWS CLI 이미 설치됨 - 스킵"
    return
  fi

  local arch
  local url
  arch=$(uname -m)

  if [ "${arch}" = "aarch64" ]; then
    url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
  else
    url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
  fi

  curl -fsSL "${url}" -o /tmp/awscliv2.zip
  cd /tmp && unzip -qo awscliv2.zip && ./aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip
}

install_ssm_agent() {
  log "[5/6] SSM Agent 설치"
  if snap list amazon-ssm-agent >/dev/null 2>&1; then
    log "SSM Agent 이미 설치됨 - 스킵"
    return
  fi

  snap install amazon-ssm-agent --classic
  systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
  systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service
}

cleanup() {
  log "[6/6] 정리"
  wait_for_apt
  apt-get autoremove -y -qq
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  rm -f /etc/wireguard/wg0.conf
  cloud-init clean --logs 2>/dev/null || true
}

main() {
  echo "============================================="
  echo " NAT AMI Build"
  echo " Region: ${AWS_REGION}"
  echo "============================================="

  install_base
  configure_sysctl
  install_nat_bootstrap
  install_awscli
  install_ssm_agent
  cleanup

  echo ""
  echo "============================================="
  echo " NAT AMI Build 완료"
  echo "============================================="
  echo "  ip_forward       : $(sysctl -n net.ipv4.ip_forward)"
  echo "  nat service      : $(systemctl is-enabled doktori-nat-ensure.service)"
  echo "  wireguard        : $(wg --version 2>&1 | head -1)"
  echo "  aws cli          : $(aws --version 2>&1 | head -1)"
  echo "  ssm agent        : $(snap list amazon-ssm-agent 2>/dev/null | tail -1 | awk '{print $2}')"
  echo "  codedeploy       : not installed (not required for NAT)"
  echo "============================================="
}

main
