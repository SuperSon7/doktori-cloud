#!/bin/bash
# =============================================================================
# K8s Node Common Setup — containerd + kubeadm (Ubuntu 24.04 ARM64)
# 모든 노드(Master + Worker)에서 동일하게 실행
# =============================================================================
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-v1.31}"

echo "===== [1/7] System prerequisites ====="

# swap 비활성화
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 커널 모듈
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# sysctl
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "===== [2/7] Install containerd ====="

apt-get update -y
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
cat <<EOF > /etc/apt/sources.list.d/docker.list
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF

apt-get update -y
apt-get install -y containerd.io

echo "===== [3/7] Configure containerd ====="

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo "===== [4/7] Install kubeadm, kubelet, kubectl ====="

apt-get install -y apt-transport-https gpg

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /
EOF

apt-get update -y
apt-get install -y kubelet kubeadm kubectl conntrack
apt-mark hold kubelet kubeadm kubectl

echo "===== [5/7] Install SSM Agent ====="

if ! systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then
  snap install amazon-ssm-agent --classic
  snap start amazon-ssm-agent
fi
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service

echo "===== [6/7] Install AWS CLI (ECR 인증용) ====="

apt-get install -y unzip
AWSCLI_ARCH=$([ "$(dpkg --print-architecture)" = "arm64" ] && echo "aarch64" || echo "x86_64")
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSCLI_ARCH}.zip" -o /tmp/awscliv2.zip
unzip -qo /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip

echo "===== [7/7] Set hostname from EC2 tag ====="

# IMDSv2 토큰 획득 + Name 태그로 hostname 설정
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
NAME_TAG=$(/usr/local/bin/aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Name" --region "$REGION" --query "Tags[0].Value" --output text 2>/dev/null || echo "")
if [ -n "$NAME_TAG" ] && [ "$NAME_TAG" != "None" ]; then
  hostnamectl set-hostname "$NAME_TAG"
fi

echo "===== Done! ====="
kubeadm version -o short
kubelet --version
kubectl version --client --short 2>/dev/null || kubectl version --client
aws --version
echo "SSM Agent: $(snap list amazon-ssm-agent 2>/dev/null | tail -1 || echo 'not found')"
echo "Hostname: $(hostname)"