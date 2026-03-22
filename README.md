# Doktori Cloud Infrastructure

5팀 Doktori 서비스의 인프라, 배포, 모니터링을 관리하는 레포지토리입니다.

## 브랜치 전략

```
main (stable)
 └── feature/* (작업 브랜치)

local-dev (orphan, 팀원 온보딩 전용)
```

### main

- 운영 인프라와 동기화된 안정 브랜치
- 직접 push 금지, feature 브랜치에서 PR 후 머지
- `terraform plan`이 clean한 상태를 유지

### feature/*

- 모든 인프라 변경은 `feature/<작업명>`에서 진행
- 작업 완료 후 main에 머지
- 네이밍: `feature/terraform-state-split`, `feature/loadtest`, `fix/sg-rule` 등

### local-dev

- 팀원 로컬 개발 환경 전용 (docker-compose, Makefile만 포함)
- main과 히스토리 공유하지 않는 orphan 브랜치
- 팀원은 이 브랜치만 clone하여 사용

## IaC CI/CD 전략

### 현재: GitHub Actions

```
feature branch → PR → terraform plan (자동) → review → merge → terraform apply
```

- PR 생성 시 `terraform plan` 자동 실행, 변경사항을 코멘트로 표시
- main 머지 시 `terraform apply` 실행 (승인 후)
- State는 S3 + DynamoDB lock으로 관리

### 향후: ArgoCD 통합

K8s 전환 시 ArgoCD를 도입하여 GitOps 워크플로우 구축 예정:

```
main push → ArgoCD sync → K8s cluster apply
```

- Terraform: 인프라 프로비저닝 (VPC, EKS, RDS 등)
- ArgoCD: 애플리케이션 배포 (manifest 기반 자동 sync)
- Helm/Kustomize로 환경별 설정 분리

## 컴포넌트 버전 매트릭스

> 최종 업데이트: 2026-03-22

### 클러스터 코어

| 컴포넌트 | 버전 | 정의 위치 | 비고 |
|---------|------|----------|------|
| Kubernetes (kubeadm) | 1.34 | `packer/variables.pkr.hcl`, `k8s/node-setup.sh` | EOL: 2026-10 |
| containerd | 1.7.25 | `packer/variables.pkr.hcl` | 1.7.x LTS, EOL 2026-09 |
| Calico CNI | 3.31.4 | `k8s/cluster-init.sh` | VXLAN 모드 |
| CoreDNS | 1.12.4 | K8s 번들 | kubeadm 자동 설치 |
| Gateway API CRD | 1.4.1 | `k8s/cluster-init.sh` | |
| Ubuntu | 22.04 LTS | Packer AMI | 지원: 2027-04 |

### Helm 릴리스 (부트스트랩 시 설치)

| 컴포넌트 | Chart 버전 | App 버전 | 관리 주체 | 정의 위치 |
|---------|-----------|---------|----------|----------|
| ArgoCD | 8.0.0+ | 3.2.x | Helm standalone | `k8s/config.env` |
| NGINX Gateway Fabric | 2.4.2 | 2.4.2 | Helm standalone | `k8s/cluster-init.sh` |

### ArgoCD 관리 (Helm App)

| 컴포넌트 | Chart 버전 | App 버전 | 정의 위치 |
|---------|-----------|---------|----------|
| metrics-server | 3.12.2 | 0.7.2 | `k8s/manifests/argocd/apps/metrics-server.yaml` |
| kube-state-metrics | 5.28.1 | 2.13.0 | `k8s/manifests/argocd/apps/kube-state-metrics.yaml` |
| External Secrets | 2.2.0 | 2.2.0 | `k8s/manifests/argocd/apps/external-secrets.yaml` |

### ArgoCD 관리 (Raw Manifest)

| 컴포넌트 | 버전 | 정의 위치 |
|---------|------|----------|
| Alloy (Grafana) | 1.14.1 | `k8s/config.env`, `k8s/manifests/monitoring/alloy-daemonset.yaml` |
| 워크로드 (api, chat) | - | `k8s/manifests/workloads/` |
| HPA | - | `k8s/manifests/hpa/` |
| NetworkPolicy | - | `k8s/manifests/security/` |
| ExternalSecret CR | - | `k8s/manifests/external-secrets/` |

### 기타

| 컴포넌트 | 버전 | 정의 위치 |
|---------|------|----------|
| Terraform | 1.14.x | 로컬 설치 |
| Helm | 3.x | 노드 설치 스크립트 |
| Chaos Mesh | 2.7.2 | `k8s/install-chaos-mesh.sh` |
| ECR credential provider | v1.31.0 | `ansible/roles/k8s-post-bootstrap/tasks/ecr-credential-provider.yml` |

## 디렉토리 구조

```
├── terraform/               # IaC (리소스 타입별 분리)
│   ├── networking/          # VPC, Subnet, IGW, Route Table
│   ├── compute/             # App EC2, SG, EIP, IAM Role
│   ├── monitoring/          # Monitoring EC2, SG, EIP
│   ├── iam/                 # OIDC, GHA Role, IAM Users
│   ├── dns/                 # Route53 Zone + Records
│   ├── lightsail/           # Lightsail Instances
│   ├── s3/                  # S3 Buckets
│   ├── parameter-store/     # KMS + SSM Parameters
│   └── backend/             # Terraform state S3 + DynamoDB
├── ansible/                 # 서버 설정 자동화 (Prometheus, Loki, Promtail)
├── monitoring/              # 모니터링 스택 (Grafana, Prometheus, Alertmanager)
├── nginx/
│   ├── docker/              # 로컬 docker-compose용
│   └── prod/                # EC2 프로덕션용 (SSL, 보안)
├── load-tests/              # k6 부하테스트 시나리오
├── docker-compose.yml       # 로컬 개발 환경
├── Makefile                 # make setup / up / down
└── LOCAL_DEV_GUIDE.md       # 로컬 개발 환경 상세 가이드
```

## 시작하기

### 인프라 관리자

```bash
git clone https://github.com/100-hours-a-week/5-team-service-cloud.git
```

### 팀원 (로컬 개발)

```bash
git clone -b local-dev https://github.com/100-hours-a-week/5-team-service-cloud.git doktori
cd doktori
make setup
# .env 파일 수정 (팀 노션 참고)
make up
```

자세한 가이드: [LOCAL_DEV_GUIDE.md](LOCAL_DEV_GUIDE.md)
