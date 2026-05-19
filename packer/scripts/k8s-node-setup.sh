#!/usr/bin/env bash
# =============================================================================
# K8s Node AMI Setup — static base for kubeadm nodes
#
# Packer provisioner로 실행됨
# 환경변수: K8S_VERSION, CONTAINERD_VERSION, CNI_PLUGINS_VERSION,
#          ECR_PROVIDER_VERSION, CRICTL_VERSION, NERDCTL_VERSION
# =============================================================================
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-v1.34}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-1.7.25-1}"
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-1.7.1}"
ECR_PROVIDER_VERSION="${ECR_PROVIDER_VERSION:-v1.31.0}"
CRICTL_VERSION="${CRICTL_VERSION:-v1.34.0}"
NERDCTL_VERSION="${NERDCTL_VERSION:-1.7.7}"

ARCH="$(dpkg --print-architecture)"
UNAME_ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ] || [ "$UNAME_ARCH" != "aarch64" ]; then
  echo "Unsupported architecture: dpkg=${ARCH}, uname=${UNAME_ARCH}. This AMI build is arm64-only."
  exit 1
fi

echo "============================================="
echo " K8s Node AMI Build"
echo " K8s: ${K8S_VERSION} / containerd: ${CONTAINERD_VERSION}"
echo " CNI plugins: ${CNI_PLUGINS_VERSION}"
echo " ECR credential provider: ${ECR_PROVIDER_VERSION}"
echo " crictl: ${CRICTL_VERSION} / nerdctl: ${NERDCTL_VERSION}"
echo "============================================="

# -----------------------------------------------------------------------------
# 1. 시스템 업데이트 + 필수 패키지
# -----------------------------------------------------------------------------
echo "[1/12] 필수 패키지 설치..."

# cloud-init이 apt lock을 잡고 있을 수 있음 — 최대 60초 대기
for i in $(seq 1 12); do
  if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then break; fi
  echo "  → apt lock 대기 중... ($i/12)"
  sleep 5
done

# universe repo 활성화 (conntrack, socat 등)
apt-get update
apt-get install -y software-properties-common
add-apt-repository -y universe
apt-get update
apt-get install -y \
  apt-transport-https bash-completion ca-certificates chrony curl dnsutils \
  ethtool gnupg htop iproute2 iptables jq less logrotate lsof net-tools nfs-common \
  openssl psmisc rsync socat tcpdump traceroute unzip vim \
  conntrack

# -----------------------------------------------------------------------------
# 2. swap 비활성화 + 커널 모듈 + sysctl
# -----------------------------------------------------------------------------
echo "[2/12] 시스템 설정 (swap off, kernel modules, sysctl)..."

swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
systemctl mask swap.target

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
systemctl enable chrony

# -----------------------------------------------------------------------------
# 3. 기본 디렉터리/로그 구조
# -----------------------------------------------------------------------------
echo "[3/12] 기본 디렉터리 및 로그 구조 생성..."

install -d -m 0755 \
  /etc/containerd \
  /etc/cni/net.d \
  /etc/kubernetes \
  /etc/kubernetes/manifests \
  /etc/kubernetes/pki \
  /opt/cni/bin \
  /opt/doktori/bin \
  /opt/doktori/logs \
  /var/lib/containerd \
  /var/lib/kubelet \
  /var/log/containers \
  /var/log/kubernetes

cat >/etc/logrotate.d/kubernetes-bootstrap <<'EOF'
/var/log/kubernetes/*.log /opt/doktori/logs/*.log {
  daily
  rotate 14
  compress
  missingok
  notifempty
  copytruncate
}
EOF

# -----------------------------------------------------------------------------
# 4. containerd 설치 (버전 핀닝)
# -----------------------------------------------------------------------------
echo "[4/12] containerd ${CONTAINERD_VERSION} 설치..."

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
  echo "  → 지정 containerd 버전(${CONTAINERD_VERSION}) 없음"
  exit 1
fi
apt-mark hold containerd.io

# -----------------------------------------------------------------------------
# 5. containerd 설정 (SystemdCgroup = true)
# -----------------------------------------------------------------------------
echo "[5/12] containerd 설정..."

containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sed -i 's|sandbox_image = "registry.k8s.io/pause:3.8"|sandbox_image = "registry.k8s.io/pause:3.10.1"|g' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

# -----------------------------------------------------------------------------
# 6. kubeadm, kubelet, kubectl 설치
# -----------------------------------------------------------------------------
echo "[6/12] kubeadm + kubelet + kubectl ${K8S_VERSION} 설치..."

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" > \
  /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# -----------------------------------------------------------------------------
# 7. CNI plugin binaries
# -----------------------------------------------------------------------------
echo "[7/12] CNI plugin binaries ${CNI_PLUGINS_VERSION} 설치..."

curl -fsSL \
  "https://github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/cni-plugins-linux-arm64-v${CNI_PLUGINS_VERSION}.tgz" \
  -o /tmp/cni-plugins.tgz
tar -xzf /tmp/cni-plugins.tgz -C /opt/cni/bin
rm -f /tmp/cni-plugins.tgz

# -----------------------------------------------------------------------------
# 8. ECR credential provider
# -----------------------------------------------------------------------------
echo "[8/12] ECR credential provider ${ECR_PROVIDER_VERSION} 설치..."

curl -fsSL \
  "https://storage.googleapis.com/k8s-artifacts-prod/binaries/cloud-provider-aws/${ECR_PROVIDER_VERSION}/linux/arm64/ecr-credential-provider-linux-arm64" \
  -o /usr/local/bin/ecr-credential-provider
chmod 0755 /usr/local/bin/ecr-credential-provider

cat >/etc/kubernetes/ecr-credential-provider-config.yaml <<'EOF'
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
      - "*.dkr.ecr.*.amazonaws.com.cn"
      - "*.dkr.ecr-fips.*.amazonaws.com"
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
EOF

cat >/etc/default/kubelet <<'EOF'
KUBELET_EXTRA_ARGS="--image-credential-provider-config=/etc/kubernetes/ecr-credential-provider-config.yaml --image-credential-provider-bin-dir=/usr/local/bin"
EOF

# -----------------------------------------------------------------------------
# 9. crictl / nerdctl
# -----------------------------------------------------------------------------
echo "[9/12] crictl ${CRICTL_VERSION} / nerdctl ${NERDCTL_VERSION} 설치..."

curl -fsSL \
  "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-arm64.tar.gz" \
  -o /tmp/crictl.tgz
tar -xzf /tmp/crictl.tgz -C /usr/local/bin crictl
rm -f /tmp/crictl.tgz

cat >/etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
pull-image-on-create: false
EOF

curl -fsSL \
  "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION}-linux-arm64.tar.gz" \
  -o /tmp/nerdctl.tgz
tar -xzf /tmp/nerdctl.tgz -C /usr/local/bin nerdctl
rm -f /tmp/nerdctl.tgz
chmod 0755 /usr/local/bin/crictl /usr/local/bin/nerdctl

# -----------------------------------------------------------------------------
# 10. Helm 3
# -----------------------------------------------------------------------------
echo "[10/12] Helm 설치..."

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# -----------------------------------------------------------------------------
# 11. AWS CLI v2
# -----------------------------------------------------------------------------
echo "[11/12] AWS CLI v2 설치..."

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
cd /tmp && unzip -qo awscliv2.zip && ./aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip

# -----------------------------------------------------------------------------
# 12. SSM Agent
# -----------------------------------------------------------------------------
echo "[12/12] SSM Agent 설치..."

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
echo "  cni plugins  : $(ls /opt/cni/bin 2>/dev/null | wc -l) binaries"
echo "  ecr provider : $(/usr/local/bin/ecr-credential-provider -v 2>/dev/null || echo installed)"
echo "  crictl       : $(crictl --version 2>/dev/null)"
echo "  nerdctl      : $(nerdctl --version 2>/dev/null)"
echo "  helm         : $(helm version --short 2>/dev/null)"
echo "  aws cli      : $(aws --version 2>&1 | head -1)"
echo "  ssm agent    : $(snap list amazon-ssm-agent 2>/dev/null | tail -1 | awk '{print $2}')"
echo "  log dirs     : /var/log/kubernetes, /var/log/containers, /opt/doktori/logs"
echo "============================================="
