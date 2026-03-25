#!/bin/bash
# =============================================================================
# K8s Master Init — kubeadm init + Calico CNI (AWS VPC용 VXLAN)
# Master 노드에서 실행. 완료 후 출력되는 kubeadm join 명령을 저장할 것.
# =============================================================================
set -euo pipefail

CALICO_VERSION="${CALICO_VERSION:-v3.29.7}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-172.16.0.0/16}"

MASTER_IP=$(hostname -I | awk '{print $1}')
echo "===== Master IP: ${MASTER_IP} ====="

# --- 1. kubeadm init ---
echo "===== [1/4] kubeadm init ====="
kubeadm init \
  --apiserver-advertise-address="${MASTER_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --service-cidr="${SERVICE_CIDR}" \
  --cri-socket=unix:///run/containerd/containerd.sock \
  | tee /tmp/kubeadm-init-output.txt

echo ""
echo "===== join 명령이 /tmp/kubeadm-init-output.txt 에 저장됨 ====="

# --- 2. kubectl 설정 ---
echo "===== [2/4] kubectl config ====="
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~${REAL_USER}")
mkdir -p "${REAL_HOME}/.kube"
cp -f /etc/kubernetes/admin.conf "${REAL_HOME}/.kube/config"
chown "$(id -u "${REAL_USER}"):$(id -g "${REAL_USER}")" "${REAL_HOME}/.kube/config"
export KUBECONFIG="${REAL_HOME}/.kube/config"

# --- 3. Calico CNI 설치 (VXLAN + BGP Disabled) ---
echo "===== [3/4] Calico ${CALICO_VERSION} 설치 ====="
kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

curl -sO "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"
sed -i 's/encapsulation: .*/encapsulation: VXLAN/' custom-resources.yaml
sed -i '/calicoNetwork:/a\    bgp: Disabled' custom-resources.yaml
kubectl create -f custom-resources.yaml

# --- 4. 대기 및 검증 ---
echo "===== [4/4] Calico Pod 대기 (최대 3분) ====="
for i in $(seq 1 18); do
  READY=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | grep -c "1/1" || true)
  TOTAL=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | wc -l || true)
  echo "  [${i}/18] calico-system: ${READY}/${TOTAL} Ready"
  if [ "${READY}" -ge 3 ] 2>/dev/null; then
    echo "===== Calico Ready! ====="
    break
  fi
  sleep 10
done

echo ""
kubectl get nodes
echo ""
echo "===== 다음 단계: Worker에서 아래 명령 실행 ====="
grep -A1 "kubeadm join" /tmp/kubeadm-init-output.txt | tail -2