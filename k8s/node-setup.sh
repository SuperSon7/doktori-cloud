#!/usr/bin/env bash
# =============================================================================
# 모든 노드 공통 설정 (Master + Worker)
# containerd + kubeadm + kubelet + kubectl 설치
#
# 사용법: 각 노드(SSM)에서 실행
#   sudo bash node-setup.sh <hostname>
#   예: sudo bash node-setup.sh k8s-master
#       sudo bash node-setup.sh k8s-worker-1
# =============================================================================
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: sudo bash $0 <hostname>"
  echo "  예: sudo bash $0 k8s-master"
  echo "      sudo bash $0 k8s-worker-1"
  exit 1
fi

NODE_HOSTNAME="$1"
K8S_VERSION="v1.34"

echo "============================================="
echo " 노드 초기화: ${NODE_HOSTNAME}"
echo " K8s 버전: ${K8S_VERSION}"
echo "============================================="

# -----------------------------------------------------------------------------
# 1. hostname 설정
# -----------------------------------------------------------------------------
echo "[1/6] hostname 설정..."
hostnamectl set-hostname "${NODE_HOSTNAME}"
echo "  → $(hostname)"

# -----------------------------------------------------------------------------
# 2. swap 비활성화 + 커널 모듈 + sysctl
# -----------------------------------------------------------------------------
echo "[2/6] 시스템 설정..."

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

echo "  → swap off, kernel modules loaded, sysctl applied"

# -----------------------------------------------------------------------------
# 3. containerd 설치
# -----------------------------------------------------------------------------
echo "[3/6] containerd 설치..."

apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg > /dev/null

install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq containerd.io > /dev/null

echo "  → containerd installed"

# -----------------------------------------------------------------------------
# 4. containerd 설정 (SystemdCgroup = true)
# -----------------------------------------------------------------------------
echo "[4/6] containerd 설정..."

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo "  → SystemdCgroup = true"

# -----------------------------------------------------------------------------
# 5. kubeadm, kubelet, kubectl 설치
# -----------------------------------------------------------------------------
echo "[5/6] kubeadm + kubelet + kubectl 설치..."

apt-get install -y -qq apt-transport-https gpg > /dev/null

if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" > \
  /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl conntrack > /dev/null
apt-mark hold kubelet kubeadm kubectl

echo "  → $(kubeadm version -o short)"

# -----------------------------------------------------------------------------
# 6. AWS CLI 설치 (없으면)
# -----------------------------------------------------------------------------
echo "[6/6] AWS CLI 확인..."

if ! command -v aws &>/dev/null; then
  ARCH=$(uname -m)
  if [ "$ARCH" = "aarch64" ]; then
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
  else
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  fi
  cd /tmp && unzip -qo awscliv2.zip && ./aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip
  echo "  → AWS CLI installed"
else
  echo "  → AWS CLI already installed: $(aws --version 2>&1 | head -1)"
fi

# -----------------------------------------------------------------------------
# 검증
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo " 완료 — 검증"
echo "============================================="
echo "  hostname     : $(hostname)"
echo "  swap         : $(free -h | grep Swap | awk '{print $2}')"
echo "  br_netfilter : $(lsmod | grep -c br_netfilter) loaded"
echo "  ip_forward   : $(sysctl -n net.ipv4.ip_forward)"
echo "  containerd   : $(systemctl is-active containerd)"
echo "  SystemdCgroup: $(containerd config dump 2>/dev/null | grep -c 'SystemdCgroup = true') (1=OK)"
echo "  kubeadm      : $(kubeadm version -o short)"
echo "  kubelet      : $(kubelet --version 2>/dev/null | awk '{print $2}')"
echo "  kubectl      : $(kubectl version --client -o yaml 2>/dev/null | grep gitVersion | awk '{print $2}')"
echo "  aws cli      : $(aws --version 2>&1 | head -1)"
echo ""
echo " 다음 단계:"
echo "   Master: ./cluster-init.sh"
echo "   Worker: kubeadm join (master에서 출력된 명령 실행)"
echo "============================================="