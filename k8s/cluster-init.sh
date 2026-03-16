#!/usr/bin/env bash
# =============================================================================
# Master 노드에서 실행 — kubeadm init + Calico CNI + Helm 설치
#
# 사용법: master 노드에서 실행 (sudo 필요)
#   sudo bash cluster-init.sh
#
# node-setup.sh 실행 후에 사용할 것
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.env"

POD_CIDR="192.168.0.0/16"
SERVICE_CIDR="172.16.0.0/16"
CALICO_VERSION="v3.29.3"
GATEWAY_API_VERSION="v1.4.1"
NGF_VERSION="1.6.2"

MASTER_IP=$(hostname -I | awk '{print $1}')

echo "============================================="
echo " 클러스터 초기화"
echo " Master IP: ${MASTER_IP}"
echo " Pod CIDR : ${POD_CIDR}"
echo " Svc CIDR : ${SERVICE_CIDR}"
echo "============================================="

# -----------------------------------------------------------------------------
# 1. kubeadm init
# -----------------------------------------------------------------------------
echo ""
echo "[1/5] kubeadm init..."

if [ -f /etc/kubernetes/admin.conf ]; then
  echo "  → 이미 초기화됨. 건너뜀."
  echo "  → 재초기화 필요 시: sudo kubeadm reset && sudo rm -rf /etc/cni/net.d"
else
  kubeadm init \
    --apiserver-advertise-address="${MASTER_IP}" \
    --pod-network-cidr="${POD_CIDR}" \
    --service-cidr="${SERVICE_CIDR}" \
    --cri-socket=unix:///run/containerd/containerd.sock

  echo ""
  echo "  ★ 위의 'kubeadm join' 명령을 반드시 저장하세요!"
  echo ""
fi

# kubectl 설정 (현재 유저)
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~${REAL_USER}")

mkdir -p "${REAL_HOME}/.kube"
cp -f /etc/kubernetes/admin.conf "${REAL_HOME}/.kube/config"
chown "$(id -u "${REAL_USER}"):$(id -g "${REAL_USER}")" "${REAL_HOME}/.kube/config"

export KUBECONFIG="${REAL_HOME}/.kube/config"

echo "  → kubectl 설정 완료 (${REAL_HOME}/.kube/config)"

# root에서도 kubectl 사용 가능하도록
export KUBECONFIG="${REAL_HOME}/.kube/config"

# -----------------------------------------------------------------------------
# 2. Calico CNI (VXLAN + BGP Disabled for AWS)
# -----------------------------------------------------------------------------
echo ""
echo "[2/5] Calico ${CALICO_VERSION} 설치..."

if kubectl get installation default &>/dev/null 2>&1; then
  echo "  → Calico 이미 설치됨. 건너뜀."
else
  kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

  # custom-resources.yaml 다운로드 + AWS용 수정
  curl -sO "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"
  sed -i 's/encapsulation: .*/encapsulation: VXLAN/' custom-resources.yaml
  sed -i '/calicoNetwork:/a\    bgp: Disabled' custom-resources.yaml

  kubectl create -f custom-resources.yaml
  rm -f custom-resources.yaml

  echo "  → Calico 설치됨. VXLAN 모드, BGP Disabled."
  echo "  → Pod 시작까지 1~3분 소요. 대기 중..."

  # Calico Pod Ready 대기
  kubectl wait --for=condition=Ready pod -l k8s-app=calico-node -n calico-system --timeout=180s 2>/dev/null || \
    echo "  ⚠ Calico Pod 아직 Ready 아님. 수동 확인: kubectl get pods -n calico-system"
fi

# 노드 Ready 확인
echo ""
kubectl get nodes

# -----------------------------------------------------------------------------
# 3. Helm 설치
# -----------------------------------------------------------------------------
echo ""
echo "[3/5] Helm 설치..."

if command -v helm &>/dev/null; then
  echo "  → 이미 설치됨: $(helm version --short)"
else
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  echo "  → Helm 설치 완료: $(helm version --short)"
fi

# -----------------------------------------------------------------------------
# 4. Gateway API CRD
# -----------------------------------------------------------------------------
echo ""
echo "[4/5] Gateway API CRD ${GATEWAY_API_VERSION}..."

if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null 2>&1; then
  echo "  → 이미 설치됨."
else
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  echo "  → Gateway API CRD 설치 완료."
fi

# -----------------------------------------------------------------------------
# 5. NGINX Gateway Fabric (Helm OCI)
# -----------------------------------------------------------------------------
echo ""
echo "[5/5] NGINX Gateway Fabric ${NGF_VERSION}..."

if helm status nginx-gw -n nginx-gateway &>/dev/null 2>&1; then
  echo "  → 이미 설치됨."
else
  helm install nginx-gw oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
    --version "${NGF_VERSION}" \
    --namespace nginx-gateway \
    --create-namespace \
    --set service.type=NodePort \
    --set "service.ports[0].port=80,service.ports[0].targetPort=80,service.ports[0].nodePort=30080,service.ports[0].protocol=TCP,service.ports[0].name=http" \
    --set "service.ports[1].port=443,service.ports[1].targetPort=443,service.ports[1].nodePort=30443,service.ports[1].protocol=TCP,service.ports[1].name=https"
  echo "  → NGF 설치 완료 (NodePort 30080/30443)"
fi

# -----------------------------------------------------------------------------
# 완료
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo " 클러스터 초기화 완료"
echo "============================================="
echo ""
kubectl get nodes
echo ""
kubectl get pods -A | grep -v Completed
echo ""
echo " 다음 단계:"
echo "   1. 각 Worker에서 'sudo kubeadm join ...' 실행"
echo "   2. Worker label: kubectl label node k8s-worker-N node-role.kubernetes.io/worker=worker"
echo "   3. 워크로드 배포: ./deploy-workloads.sh"
echo ""
echo " Worker join 명령 재생성 (토큰 만료 시):"
echo "   kubeadm token create --print-join-command"
echo "============================================="