#!/usr/bin/env bash
# =============================================================================
# K8s Node AMI Setup — containerd + kubeadm + kubelet + kubectl + AWS CLI + SSM
#
# Packer provisioner로 실행됨
# 환경변수: K8S_VERSION, CONTAINERD_VERSION
# =============================================================================
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-v1.31}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-1.7.24-1}"

echo "============================================="
echo " K8s Node AMI Build"
echo " K8s: ${K8S_VERSION} / containerd: ${CONTAINERD_VERSION}"
echo "============================================="

# -----------------------------------------------------------------------------
# 1. 시스템 업데이트 + 필수 패키지
# -----------------------------------------------------------------------------
echo "[1/7] 필수 패키지 설치..."
apt-get update -qq
apt-get install -y -qq \
  ca-certificates curl gnupg apt-transport-https \
  unzip jq htop net-tools

# -----------------------------------------------------------------------------
# 2. swap 비활성화 + 커널 모듈 + sysctl
# -----------------------------------------------------------------------------
echo "[2/7] 시스템 설정 (swap off, kernel modules, sysctl)..."

swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system > /dev/null 2>&1

# -----------------------------------------------------------------------------
# 3. containerd 설치 (버전 핀닝)
# -----------------------------------------------------------------------------
echo "[3/7] containerd ${CONTAINERD_VERSION} 설치..."

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

apt-get update -qq
if apt-cache show "containerd.io=${CONTAINERD_VERSION}" > /dev/null 2>&1; then
  apt-get install -y -qq "containerd.io=${CONTAINERD_VERSION}"
else
  echo "  → 지정 버전(${CONTAINERD_VERSION}) 없음, latest 설치"
  apt-get install -y -qq containerd.io
fi
apt-mark hold containerd.io

# -----------------------------------------------------------------------------
# 4. containerd 설정 (SystemdCgroup = true)
# -----------------------------------------------------------------------------
echo "[4/7] containerd 설정..."

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

# -----------------------------------------------------------------------------
# 5. kubeadm, kubelet, kubectl 설치
# -----------------------------------------------------------------------------
echo "[5/7] kubeadm + kubelet + kubectl ${K8S_VERSION} 설치..."

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" > \
  /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# -----------------------------------------------------------------------------
# 6. AWS CLI v2
# -----------------------------------------------------------------------------
echo "[6/7] AWS CLI v2 설치..."

ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
else
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
fi
cd /tmp && unzip -qo awscliv2.zip && ./aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip

# -----------------------------------------------------------------------------
# 7. SSM Agent
# -----------------------------------------------------------------------------
echo "[7/7] SSM Agent 설치..."

snap install amazon-ssm-agent --classic
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
apt-get autoremove -y -qq
apt-get clean
rm -rf /var/lib/apt/lists/*

# cloud-init 히스토리 정리 (AMI 재사용 시 깨끗한 시작)
cloud-init clean --logs 2>/dev/null || true

# -----------------------------------------------------------------------------
# 검증
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo " K8s Node AMI Build 완료"
echo "============================================="
echo "  containerd   : $(containerd --version)"
echo "  kubeadm      : $(kubeadm version -o short)"
echo "  kubelet      : $(kubelet --version 2>/dev/null | awk '{print $2}')"
echo "  kubectl      : $(kubectl version --client -o yaml 2>/dev/null | grep gitVersion | awk '{print $2}')"
echo "  aws cli      : $(aws --version 2>&1 | head -1)"
echo "  ssm agent    : $(snap list amazon-ssm-agent 2>/dev/null | tail -1 | awk '{print $2}')"
echo "============================================="