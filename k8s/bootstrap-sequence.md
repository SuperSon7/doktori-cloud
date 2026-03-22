# K8s Cluster Bootstrap Sequence

완전한 클러스터 부트스트랩 순서. 각 Phase는 순서대로 실행해야 한다.

---

## Phase -1 — Pre-Bootstrap Cleanup (클러스터 재생성 시 필수)

이전 클러스터의 SSM 파라미터가 남아있으면 리더 선출이 실패한다. **반드시** 삭제 후 진행.

```bash
aws ssm delete-parameters --names \
  "/doktori/prod/k8s/init-lock" \
  "/doktori/prod/k8s/join-command" \
  "/doktori/prod/k8s/master-join-command" \
  "/doktori/prod/k8s/certificate-key" \
  --region ap-northeast-2
```

## Phase 0 — Node Preparation (ALL nodes, user_data 또는 Ansible)

클러스터 초기화 전, 모든 노드에서 실행.

### 0-1. ECR Credential Provider 설치

kubelet 레벨에서 ECR 인증을 처리한다. ECR token refresh CronJob을 대체.

```bash
# 바이너리 다운로드
ECR_PROVIDER_VERSION="v1.31.0"
ARCH="arm64"
curl -Lo /usr/local/bin/ecr-credential-provider \
  "https://artifacts.k8s.io/binaries/cloud-provider-aws/${ECR_PROVIDER_VERSION}/linux/${ARCH}/ecr-credential-provider-linux-${ARCH}"
chmod +x /usr/local/bin/ecr-credential-provider
```

### 0-2. Credential Provider Config 생성

```bash
cat > /etc/kubernetes/ecr-credential-provider-config.yaml <<'EOF'
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
```

### 0-3. kubelet 플래그 (kubeadm join 이후)

kubeadm join 완료 후 `/var/lib/kubelet/kubeadm-flags.env`에 플래그 추가:

```bash
# 기존 KUBELET_KUBEADM_ARGS 끝에 추가
--image-credential-provider-config=/etc/kubernetes/ecr-credential-provider-config.yaml
--image-credential-provider-bin-dir=/usr/local/bin/
```

> Ansible role `k8s-post-bootstrap/tasks/ecr-credential-provider.yml` 로 자동화 가능.

---

## Phase 1 — Cluster Init (kubeadm)

Terraform user_data + SSM 조율로 자동화되어 있음.

1. Master: `kubeadm init` (CNI: Cilium)
2. Workers: SSM에서 join token 수신 후 `kubeadm join`
3. Cilium 설치 확인: `kubectl get pods -n kube-system -l k8s-app=cilium`

---

## Phase 2 — Post-Bootstrap (first master only)

### 2-1. Helm 설치

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### 2-2. NGINX Gateway Fabric (NGF)

```bash
helm repo add nginx-gateway https://kubernetes-sigs.github.io/nginx-gateway-fabric
helm repo update
helm install nginx-gateway-fabric nginx-gateway/nginx-gateway-fabric \
  --namespace nginx-gateway --create-namespace
```

**필수 패치 — externalTrafficPolicy**:
```bash
kubectl patch svc nginx-gateway-fabric -n nginx-gateway \
  -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
```

> **Gotcha**: `externalTrafficPolicy: Local` (기본값)이면 NodePort가 해당 Pod이 실행 중인
> 노드에서만 응답 → ALB 타겟 중 1개만 healthy → 나머지 502 반환.
> `Cluster`로 변경하면 모든 노드에서 트래픽을 수신하고 내부 라우팅.

### 2-3. External Secrets Operator (ESO)

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace
```

### 2-4. ArgoCD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 8.0.14 \
  -f k8s/helm/argocd-values.yaml
```

또는 통합 스크립트 사용:
```bash
./k8s/bootstrap-argocd.sh --install
```

### 2-5. Namespace 생성

```bash
kubectl create namespace prod
kubectl create namespace monitoring
```

> **Gotcha**: Namespace가 존재해야 NetworkPolicy, ExternalSecret 등을 apply 할 수 있다.

### 2-6. ClusterSecretStore 적용

```bash
kubectl apply -f k8s/manifests/external-secrets/cluster-secret-store.yaml
```

IMDS (Instance Profile)로 AWS 인증. IRSA 불필요.

- Manifest: `k8s/manifests/external-secrets/cluster-secret-store.yaml`
- API version: `external-secrets.io/v1` (v1beta1 아님)

### 2-7. ExternalSecret 적용

```bash
kubectl apply -f k8s/manifests/external-secrets/external-secret-firebase.yaml
```

- `prod` namespace에 `firebase-credentials` Secret 생성
- SSM Parameter Store key: `/doktori/prod/FIREBASE_SERVICE_ACCOUNT`
- Secret key: `firebase-service-account.json` (Deployment volumeMount과 일치해야 함)

> **Gotcha**: Firebase secret name이 Deployment의 volumeMount 이름과 정확히 일치해야 한다.
> 불일치 시 Pod이 `CreateContainerConfigError`로 시작 실패.

### 2-8. NetworkPolicy 적용

```bash
kubectl apply -f k8s/manifests/security/netpol-all.yaml
```

적용 대상 namespace별 정책:

| Namespace | Ingress | Egress |
|-----------|---------|--------|
| **prod** | default-deny + NGF/monitoring 허용 | default-deny + IMDS/DNS/VPC(443)/서비스포트 허용 |
| **monitoring** | default-deny + alloy 내부 허용 | default-deny + IMDS/DNS/스크래핑/remote_write 허용 |
| **external-secrets** | (별도 정책 필요 시 추가) | default-deny + IMDS(80)/DNS(53)/VPC Endpoints(443) 허용 |

> **Gotcha — Egress 차단이 IMDS를 막는다**:
> `default-deny-egress`를 적용하면 169.254.169.254:80 (IMDS) 접근이 차단됨.
> Pod이 IAM credentials를 받지 못해 Spring Boot가 Parameter Store 읽기 실패.
> 반드시 IMDS egress 허용 정책을 함께 적용해야 한다.

> **Gotcha — VPC Endpoint 443도 허용해야 한다**:
> SSM Parameter Store, ECR, CloudWatch Logs 등 AWS 서비스는 VPC Endpoint를 통해 접근.
> VPC CIDR(10.1.0.0/16)의 443 포트를 열어야 한다.

### 2-9. ArgoCD 설정

```bash
./k8s/bootstrap-argocd.sh --setup --app-of-apps
```

또는 수동:

```bash
# Git 저장소 연결
kubectl create secret generic private-repo-creds \
  --namespace argocd \
  --from-literal=type=git \
  --from-literal=url="<REPO_URL>" \
  --from-literal=username="<USERNAME>" \
  --from-literal=password="<PAT>"
kubectl label secret private-repo-creds -n argocd \
  argocd.argoproj.io/secret-type=repository

# Root Application 배포 (App of Apps)
sed "s|__GIT_REPO_URL__|<REPO_URL>|g" k8s/manifests/argocd/root-app.yaml | kubectl apply -f -
```

> **Gotcha**: `__GIT_REPO_URL__` placeholder가 ArgoCD child app YAML에도 있으므로
> `application-*.yaml` 파일 전체에 sed 치환이 필요하다.

### 2-10. ECR Credential Provider 플래그 확인 (Phase 0에서 미완료 시)

모든 노드에서 확인:

```bash
# 플래그 확인
grep image-credential-provider /var/lib/kubelet/kubeadm-flags.env

# 없으면 추가
sudo sed -i 's|^KUBELET_KUBEADM_ARGS="\(.*\)"$|KUBELET_KUBEADM_ARGS="\1 --image-credential-provider-config=/etc/kubernetes/ecr-credential-provider-config.yaml --image-credential-provider-bin-dir=/usr/local/bin/"|' /var/lib/kubelet/kubeadm-flags.env
sudo systemctl restart kubelet
```

---

## Gotcha 종합

| 증상 | 원인 | 해결 |
|------|------|------|
| Spring Boot Pod `CrashLoopBackOff`, Parameter Store 읽기 실패 | Egress NetworkPolicy가 IMDS(169.254.169.254:80) 차단 | `allow-imds-egress` 정책 추가 |
| Spring Boot Pod에서 AWS 서비스 접근 불가 | Egress에서 VPC Endpoint(443) 미허용 | VPC CIDR:443 egress 허용 |
| ALB에서 502 Bad Gateway (일부 타겟만 healthy) | NGF svc `externalTrafficPolicy: Local` | `Cluster`로 패치 |
| ESO CRD apply 실패 (`no matches for kind`) | ESO API version이 `v1` (v1beta1 아님) | apiVersion 확인 |
| Pod `CreateContainerConfigError` | firebase-credentials Secret 이름 불일치 | Secret name = Deployment volumeMount name |
| RabbitMQ 연결 실패 | Parameter Store의 credentials가 실제 RabbitMQ 인스턴스와 불일치 | SSM 값 확인 |
| ECR pull 실패 (`ImagePullBackOff`) | kubelet credential provider 미설정 | Phase 0 또는 2-10 수행 |
| NetworkPolicy apply 실패 | 대상 namespace가 아직 없음 | Phase 2-5에서 namespace 먼저 생성 |
| ArgoCD child app sync 실패 | `__GIT_REPO_URL__` placeholder 미치환 | sed로 전체 application YAML 치환 |

---

## Ansible 자동화 매핑

| Phase | 수동 스크립트 | Ansible Role/Task |
|-------|-------------|-------------------|
| 0 | user_data 스크립트 | `k8s-post-bootstrap/tasks/ecr-credential-provider.yml` |
| 2-1~2-4 | `bootstrap-argocd.sh --install` | `k8s-post-bootstrap/tasks/argocd.yml` |
| 2-5~2-7 | `kubectl apply` | `k8s-post-bootstrap/tasks/workloads.yml` |
| 2-8 | `kubectl apply netpol-all.yaml` | `k8s-post-bootstrap/tasks/argocd.yml` (NetworkPolicy 섹션) |
| 2-9 | `bootstrap-argocd.sh --setup --app-of-apps` | `k8s-post-bootstrap/tasks/argocd.yml` |
| hardening | `bootstrap-argocd.sh --setup` | `k8s-post-bootstrap/tasks/hardening.yml` |

---

## 검증 체크리스트

```bash
# 1. 모든 노드 Ready
kubectl get nodes

# 2. ECR credential provider 동작 확인
kubectl run test-ecr --image=<ECR_REGISTRY>/api:latest --rm -it -- echo OK

# 3. ESO → Secret 생성 확인
kubectl get externalsecret -n prod
kubectl get secret firebase-credentials -n prod

# 4. NetworkPolicy 적용 확인
kubectl get netpol -n prod
kubectl get netpol -n monitoring

# 5. Pod → IMDS 접근 확인
kubectl exec -n prod <pod> -- curl -s http://169.254.169.254/latest/meta-data/iam/

# 6. Pod → AWS 서비스 접근 확인
kubectl exec -n prod <pod> -- curl -s https://ssm.ap-northeast-2.amazonaws.com/

# 7. ArgoCD Applications 동기화 상태
kubectl get applications -n argocd

# 8. ALB 전체 타겟 healthy
aws elbv2 describe-target-health --target-group-arn <TG_ARN>
```
