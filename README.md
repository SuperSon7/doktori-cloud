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
