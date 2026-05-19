#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
K6_VERSION="${K6_VERSION:-v0.54.0}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

retry_apt_update() {
  local attempt
  for attempt in 1 2 3; do
    rm -rf /var/lib/apt/lists/*
    if apt-get update; then
      return 0
    fi
    sleep 5
  done
  return 1
}

retry_apt_update
apt-get install -y \
  ca-certificates \
  curl \
  git \
  unzip \
  gnupg \
  lsb-release \
  apt-transport-https

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
echo \
  "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

retry_apt_update
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu || true

curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-arm64.tar.gz" \
  -o /tmp/k6.tgz
tar -xzf /tmp/k6.tgz -C /tmp
install -m 0755 /tmp/k6-${K6_VERSION}-linux-arm64/k6 /usr/local/bin/k6
rm -rf /tmp/k6.tgz /tmp/k6-${K6_VERSION}-linux-arm64

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip

snap install amazon-ssm-agent --classic || true
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service || true
systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service || true

install -d -o ubuntu -g ubuntu /home/ubuntu/monitoring

k6 version
docker --version
aws --version
