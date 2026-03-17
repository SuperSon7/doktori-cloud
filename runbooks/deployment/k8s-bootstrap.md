# K8s cluster bootstrap

Last updated: 2026-03-17
Author: jbdev

Terraform apply 후 prod K8s 클러스터(Master 3 + Worker 4, 3AZ HA)를 부트스트랩하는 전체 절차.

## Before you begin

- Terraform `prod/app` apply 완료 (ASG, NLB, SG 생성됨)
- Packer AMI에 containerd, kubeadm, kubelet, kubectl, Helm 사전 설치됨
- SSM으로 마스터/워커 노드 접근 가능
- `k8s/` 디렉토리가 마스터 노드에 존재 (git clone 또는 SCP)

## Overview

```
1. config.env 설정
2. cluster-init.sh     → kubeadm init + Calico + NGF
3. Worker join         → user_data 자동 또는 수동
4. deploy-workloads.sh → ECR 인증 + Deployments + Gateway + HTTPRoutes
5. install-observability.sh → metrics-server + kube-state-metrics + HPA + Alloy
6. install-argocd.sh   → NetworkPolicy + ArgoCD
7. setup-argocd.sh     → Git 연결 + 보안 + 비밀번호
```

## Step 1: Transfer scripts to master node

1. SSM으로 마스터 노드에 접속한다.

   ```bash
   aws ssm start-session --target <MASTER_INSTANCE_ID>
   sudo -u ubuntu bash
   cd ~
   ```

2. Cloud 레포의 k8s 디렉토리만 가져온다.

   ```bash
   git clone --depth 1 --filter=blob:none --sparse \
     https://github.com/100-hours-a-week/5-team-service-cloud.git k8s
   cd k8s
   git sparse-checkout set k8s
   cd k8s
   ```

   > **Note:** sparse checkout으로 k8s/ 폴더만 받는다. 전체 레포를 clone할 필요 없음.

## Step 2: Configure environment

1. `config.env`를 환경에 맞게 수정한다.

   ```bash
   vi config.env
   ```

   주요 설정값:
   - `NAMESPACE`: prod
   - `ECR_REGISTRY`: 250857930609.dkr.ecr.ap-northeast-2.amazonaws.com
   - `MONITORING_SERVER`: monitoring.mgmt.doktori.internal
   - Helm 차트 버전: `METRICS_SERVER_VERSION`, `KUBE_STATE_METRICS_VERSION`, `ARGOCD_CHART_VERSION`
   - `ALLOY_VERSION`: v1.9.0

## Step 3: Initialize cluster (master node)

1. cluster-init.sh를 실행한다.

   ```bash
   chmod +x cluster-init.sh
   sudo ./cluster-init.sh
   ```

   이 스크립트가 수행하는 작업:
   - `kubeadm init` (NLB endpoint 기반 HA control plane)
   - Calico CNI 설치 (VXLAN, BGP Disabled)
   - Gateway API CRD 설치
   - NGINX Gateway Fabric 설치 (NodePort 30080/30443)

2. kubeconfig를 설정한다.

   ```bash
   mkdir -p $HOME/.kube
   sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
   sudo chown $(id -u):$(id -g) $HOME/.kube/config
   ```

3. 노드 상태를 확인한다.

   ```bash
   kubectl get nodes
   ```

   > **Note:** user_data에 kubeadm init/join이 포함되어 있으면 ASG 인스턴스 기동 시 자동 실행된다. 수동 부트스트랩은 user_data가 없거나 실패한 경우에만 필요.

## Step 4: Worker join

Worker 노드는 user_data 자동 join을 사용한다. 수동 join이 필요한 경우:

1. 마스터에서 join 명령을 생성한다.

   ```bash
   kubeadm token create --print-join-command
   ```

2. 각 워커 노드에서 실행한다.

   ```bash
   sudo kubeadm join <NLB_DNS>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
   ```

3. 전체 노드 Ready 상태를 확인한다.

   ```bash
   kubectl get nodes
   # Master 3 + Worker 4 = 7 nodes, 모두 Ready
   ```

## Step 5: Deploy workloads

1. 워크로드를 배포한다.

   ```bash
   chmod +x deploy-workloads.sh
   ./deploy-workloads.sh
   ```

   배포 대상: namespace, ECR CronJob, api/chat Deployment + Service, Gateway, HTTPRoutes

2. Pod 상태를 확인한다.

   ```bash
   kubectl get pods -n prod
   # api (2 replicas), chat (2 replicas) Running
   ```

3. E2E 트래픽을 확인한다.

   ```bash
   curl http://<NLB_DNS>/api/health
   curl http://<NLB_DNS>/api/chat/health
   ```

## Step 6: Install observability

1. Observability 스택을 설치한다.

   ```bash
   chmod +x install-observability.sh
   ./install-observability.sh
   ```

   설치 항목:
   - metrics-server (HPA용)
   - kube-state-metrics (클러스터 메트릭)
   - HPA (chat/api, CPU 60% 타겟)
   - Alloy DaemonSet (메트릭 → Prometheus, 로그 → Loki)

2. 메트릭 수집을 확인한다.

   ```bash
   # 1~2분 후
   kubectl top nodes
   kubectl top pods -n prod
   ```

3. Grafana에서 확인한다.

   ```
   up{env="prod-k8s"}          → 메트릭 수신
   {env="prod-k8s"} |= ""     → 로그 수신 (Loki Explore)
   ```

## Step 7: Install ArgoCD

1. ArgoCD를 설치한다.

   ```bash
   chmod +x install-argocd.sh
   ./install-argocd.sh
   ```

2. 초기 설정을 실행한다.

   ```bash
   chmod +x setup-argocd.sh
   ./setup-argocd.sh
   ```

   인터랙티브 프롬프트:
   - Git 저장소 URL: `https://github.com/100-hours-a-week/5-team-service-cloud.git`
   - Git Username: GitHub 계정명
   - Git PAT: repo 스코프 Classic PAT

   > **Note:** [B] etcd 암호화, [C] kubelet 보안은 sudo 필요. 별도로 실행하려면 `security/k8s-hardening.md` 참조.

3. ArgoCD Application 상태를 확인한다.

   ```bash
   kubectl get applications -n argocd
   # doktori-workloads: Synced, Healthy
   # doktori-hpa: Synced, Healthy
   ```

## Verify

```bash
# 전체 노드 상태
kubectl get nodes -o wide

# 전체 Pod 상태
kubectl get pods -A

# Helm releases
helm list -A

# HPA 동작
kubectl get hpa -n prod

# ArgoCD sync 상태
kubectl get applications -n argocd
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Worker join 실패 | 토큰 만료 (24h) | 마스터에서 `kubeadm token create --print-join-command` |
| Alloy pods/log forbidden | RBAC 누락 | `alloy-rbac.yaml`에 `pods/log` 리소스 추가 확인 |
| Loki 로그 안 보임 | discovery.relabel 라벨 매핑 누락 | `alloy-configmap.yaml`에 namespace/pod/container relabel 확인 |
| ImagePullBackOff | ECR 토큰 만료 | `kubectl get cronjob -n prod` → ecr-token-refresh 수동 실행 |
| ArgoCD Progressing 유지 | 이미지 pull 실패 | `kubectl describe pod <pod> -n prod` → 이미지 태그 확인 |
| metrics-server not ready | kubelet 인증서 | `--kubelet-insecure-tls` 옵션 확인 |

## What's next

- [ArgoCD setup](argocd-setup.md)
- [K8s hardening](../security/k8s-hardening.md)
