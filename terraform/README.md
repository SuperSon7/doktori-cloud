# Doktori — Terraform Infrastructure

dev / staging / prod 3개 환경의 AWS 인프라를 관리하는 Terraform 구성.

환경은 디렉토리 기반으로 완전 분리하고, 각 환경을 base / app / data 3계층으로 나누어 변경의 영향 범위(Blast Radius) 를 최소화한다.

## Architecture

```
                          ┌─────────────────────────────────┐
                          │           global/                │
                          │  OIDC, IAM Groups, Budget Alert  │
                          └──────────────┬──────────────────┘
                                         │
               ┌─────────────────────────┼─────────────────────────┐
               │                         │                         │
        ┌──────▼──────┐           ┌──────▼──────┐          ┌──────▼──────┐
        │   dev/base  │           │staging/base │          │  prod/base  │
        │ VPC 10.0/16 │           │ VPC 10.2/16 │          │ VPC 10.1/16 │
        │ NAT+VPN inst│           │ NAT Instance│          │ NAT Instance│
        └──────┬──────┘           └──────┬──────┘          │+VPC Endpoint│
          ┌────┴────┐               ┌────┴────┐            └──────┬──────┘
        ┌─▼───┐ ┌───▼─────┐  ┌────▼───┐ ┌───▼─────┐       ┌────┴────┐
        │dev/ │ │ dev/app │  │stg/app │ │stg/data │  ┌────▼───┐ ┌──▼─────┐
        │data │ │2 inst.  │  │6 inst. │ │  RDS    │  │prod/app│ │prod/dat│
        │ S3  │ │all-in-1 │  │(micro) │ │(dispos.)│  │6 inst. │ │  RDS   │
        └─────┘ └─────────┘  └────────┘ └─────────┘  └────────┘ └────────┘

        ┌──────────────────────┐      ┌─────────────┐      ┌─────────────┐
        │     monitoring/      │      │  dns_zone/  │      │ prod CDN    │
        │  mgmt VPC 172.16/16  │      │  Route53 +  │      │ CloudFront  │
        │  base / data / app   │      │  Google WS  │      │  + S3 OAC   │
        │  (VPC Peering: dev)  │      └─────────────┘      │  + S3 OAC   │
        └──────────────────────┘                           └─────────────┘
```

## Directory Structure

```
terraform/
├── backend.hcl                    # S3 backend 공통 설정
├── backend/                       # State backend 부트스트랩 (S3)
├── global/                        # 계정 수준 리소스 (OIDC, IAM, Budget)
├── modules/
│   ├── networking/                # VPC, Subnet, NAT Instance, VPC Endpoint
│   ├── compute/                   # EC2, SG, IAM Role, EIP
│   ├── database/                  # RDS, Parameter Group, DB Password (SSM)
│   ├── storage/                   # S3, KMS, IAM (per-env)
│   └── ssm-parameters/            # SSM Parameter Store (앱 시크릿 write)
├── ecr/                           # ECR repositories (cross-env)
├── environments/
│   ├── dev/
│   │   ├── base/                  # VPC (10.0.0.0/16), NAT+VPN Instance
│   │   ├── data/                  # S3 버킷, SSM 파라미터
│   │   └── app/                   # EC2 x2 (all-in-one)
│   ├── staging/
│   │   ├── base/                  # VPC (10.2.0.0/16)
│   │   ├── data/                  # RDS (disposable)
│   │   ├── app/                   # EC2 x6 (service-per-instance)
│   │   ├── loadtest/              # k6 runner (staging 내 부하테스트)
│   │   └── prod-spec.tfvars       # Prod-equivalent specs for load testing
│   ├── prod/
│   │   ├── base/                  # VPC (10.1.0.0/16) + VPC Endpoints
│   │   ├── data/                  # RDS (protected)
│   │   ├── app/                   # EC2 x6 (service-per-instance)
│   │   └── cdn/                   # CloudFront + S3 static assets
│   └── loadtest/                  # Standalone 부하테스트 (별도 계정, remote_state 없음)
├── monitoring/                    # Prometheus + Loki + Grafana (mgmt VPC 172.16.0.0/16)
│   ├── base/                      # VPC, NAT+VPN Instance, VPC Peering
│   ├── data/                      # EBS 볼륨 (Prometheus TSDB, Loki chunks)
│   └── app/                       # EC2 (monitoring 서버), SG
└── dns_zone/                      # Route53 Hosted Zone + Google Workspace MX
```

## Prerequisites

- Terraform >= 1.10.0
- AWS CLI configured with appropriate IAM permissions
- Access to `doktori-terraform-state` S3 bucket

## Quick Start

```bash
# Single layer
cd terraform/environments/prod/base
terraform init -backend-config=../../../backend.hcl
terraform plan
terraform apply

# All layers (local plan)
./scripts/plan-all.sh              # all environments
./scripts/plan-all.sh prod         # prod only
./scripts/plan-all.sh staging dev  # staging + dev
```

### Apply Order

New environment setup requires sequential apply:

```
backend → global → ecr → dns_zone → monitoring/base → monitoring/data → monitoring/app
→ {env}/base → monitoring re-apply → {env}/data → {env}/app → prod/cdn
```

`base` must complete before `data`/`app` because they reference base outputs via `terraform_remote_state`.  
`app` must run after `data` when it reads stateful outputs such as S3 bucket ARNs, RDS endpoints, or CodeDeploy revision buckets.

### Base 변경 시 PR 분리 (필수)

`base` 레이어에 **새 output이 추가**되는 변경이 있으면 반드시 PR을 분리한다:

```
1. PR #1: base 변경만 (modules/ + base layers + outputs)
   → merge → CI가 base apply → remote state에 새 output 반영

2. PR #2: app/data 변경 (새 output을 참조하는 리소스)
   → 이제 plan이 정상 동작 → 리뷰에서 실제 변경 확인 가능
```

**이유**: app/data는 `terraform_remote_state`로 base output을 읽는다. base가 apply되기 전에는 새 output이 state에 없으므로 app/data plan이 실패한다. 한 PR에 합치면 CI plan에서 app/data 검증이 불가능하다.

`plan-all.sh`도 이 의존성을 인식하여, base에 changes가 있으면 하위 레이어를 자동으로 skip한다.

## State Management

| Item | Value |
|------|-------|
| Backend | S3 (`doktori-terraform-state`) |
| Locking | S3 native lockfile (`use_lockfile = true`) |
| Encryption | AES-256 (S3 SSE) |
| Versioning | Enabled |

공통 backend 설정은 `backend.hcl`에 정의하고, 각 레이어의 `providers.tf`에서 state key만 지정한다.

```
# State key 구조
global/terraform.tfstate
ecr/terraform.tfstate
dns_zone/terraform.tfstate
monitoring/base/terraform.tfstate
monitoring/data/terraform.tfstate
monitoring/app/terraform.tfstate
{env}/base/terraform.tfstate
{env}/data/terraform.tfstate
{env}/app/terraform.tfstate
prod/cdn/terraform.tfstate
```

> `backend/` 디렉토리에서 state S3 bucket 자체를 Terraform으로 관리 (부트스트랩).

## Environment Comparison

| | dev | staging | prod |
|---|---|---|---|
| VPC CIDR | 10.0.0.0/16 | 10.2.0.0/16 | 10.1.0.0/16 |
| Instance layout | All-in-one x2 | Service-per-instance x6 | Service-per-instance x6 |
| App subnet | Public | Private | Private |
| VPC Endpoints | None | None | SSM, ECR, Logs (x6) |
| RDS | None (EC2 MySQL) | Disposable | Protected (GTID, 7d backup) |
| S3 | doktori-dev | — | doktori-prod |
| NAT | Ubuntu NAT Instance + WireGuard VPN | Amazon Linux NAT Instance | Amazon Linux NAT Instance |
| Monitoring 연결 | VPC Peering (dev ↔ mgmt) | — | VPC Peering (prod ↔ mgmt) |

## Network CIDR Plan

| Network | CIDR | Notes |
|---|---:|---|
| dev VPC | 10.0.0.0/16 | Development environment VPC |
| prod VPC | 10.1.0.0/16 | Production environment VPC |
| staging VPC | 10.2.0.0/16 | Disposable staging VPC |
| mgmt VPC | 172.16.0.0/16 | Monitoring server and WireGuard/NAT VPC |
| prod K8s Pod CIDR | 100.64.0.0/16 | Calico pod network, outside the 10/8 VPC plan |
| prod K8s Service CIDR | 198.18.16.0/20 | ClusterIP range, avoids 10/8 and mgmt 172.16/16 |

CIDR allocation rules:

- Environment VPCs use non-overlapping `/16` blocks under `10.0.0.0/8`.
- mgmt uses `172.16.0.0/16` and must not overlap with any Kubernetes Service CIDR.
- Kubernetes Pod CIDRs use `100.64.0.0/10` space, split per cluster as needed.
- Kubernetes Service CIDRs use small `/20` blocks under `198.18.0.0/15`; do not use broad `10.96.0.0/12` because it conflicts with future `10.x.0.0/16` VPC expansion.
- Security group descriptions should read as `from <source> to <target/service>` so source CIDRs and SG references stay understandable in AWS.

## Timeout And Keepalive Plan

Ingress timeout order should keep the outer client-facing layer slightly longer than the inner service deadline, so users receive application errors instead of edge/proxy disconnects.

| Path | Timeout / keepalive | Rationale |
|---|---:|---|
| Browser API calls | 5s default, 70s for AI recommendation requests | Normal UX fails fast; AI actions can wait for model work |
| CloudFront → frontend ALB origin | connect 10s, read 60s, keepalive 60s | Site origin ceiling for `doktori.kr`; not for long-lived API/SSE/WS |
| Public ALB idle timeout | 3600s | Keeps WebSocket/SSE connections alive when using direct ALB domains |
| NGF `/api/` route | backendRequest 65s | Slightly longer than Spring's fixed AI read timeout |
| Spring API/Chat → AI service | connect 10s, read 60s | Fixed in backend code; no extra SSM timeout parameters |
| AI → RunPod | submit 8s, status 5s, poll 40s | Submit/status are fixed code constants; poll uses the existing RunPod poll timeout setting |
| NGF `/api/chat-rooms` route | backendRequest 31m | Waiting-room SSE emitter is 30m with 30s heartbeat |
| NGF `/ws/chat` route | backendRequest 1h | WebSocket lane; paired with ALB 3600s idle timeout |
| NGF upstream keepAlive | 64 connections, 1000 requests, 1h max age, 60s idle | Reuses pod upstream TCP connections without keeping idle sockets forever |

Direct real-time traffic should use `api.doktori.kr` so WebSocket/SSE bypass CloudFront and rely on ALB + NGF long-connection settings. `doktori.kr/api/*` through CloudFront is acceptable for normal/short API calls and OAuth callbacks, but not for long-lived SSE streams.

### Staging Lifecycle

staging은 상시 운영이 아닌 필요 시 기동하는 환경이다. GitHub Actions workflow dispatch로 관리:

| Action | Description |
|--------|-------------|
| `apply` | base → app + data 전체 생성 |
| `start` | EC2 + RDS 시작, nginx 헬스체크 |
| `stop` | EC2 + RDS 정지 |
| `scale` | staging ↔ prod 사양 전환 (`prod-spec.tfvars`) |
| `deploy` | api/chat 서비스 배포 |
| `destroy` | 전체 환경 삭제 (data → app → base) |

## Modules

### networking

VPC, Subnet, NAT Instance, Route Table, VPC Endpoint.

- `subnets` map으로 `for_each` 생성
- `vpc_interface_endpoints` list로 환경별 Endpoint 선택
- NAT Instance AMI/user_data 외부 주입 가능
- S3 Gateway Endpoint 기본 포함 (무료)

### compute

EC2, Security Group, IAM Role, EIP.

- `services` map으로 N개 인스턴스 선언적 정의
- `sg_cross_rules`로 SG간 참조 규칙 별도 관리
- ARM/x86 아키텍처 서비스별 선택
- `associate_eip` flag로 EIP 조건부 할당
- IMDSv2 강제, EBS 암호화 기본 적용

TODO(user_data-slim): Launch Template/EC2 `user_data`는 부팅 시 동적 조율(kubeadm init/join, SSM에서 join 정보 조회, 최소 라벨링)만 담당하게 줄인다. 정적 설치는 Packer AMI에 굽고, CNI/NGF/앱/애드온 배포는 ArgoCD/Helm/Ansible 단계로 분리한다.

### database

RDS, DB Parameter Group, Password.

- `random_password` → SSM Parameter Store (SecureString) 저장
- `db_extra_parameters`로 환경별 추가 파라미터 주입
- `deletion_protection`, `skip_final_snapshot` 환경별 제어
- `prevent_destroy` lifecycle (prod)

### storage

S3, ECR, KMS.

- `s3_buckets` map으로 버킷별 설정 (public_read, CORS, 암호화)
- ECR lifecycle policy (최근 10개 이미지 유지)
- KMS key rotation 활성화

### ssm-parameters

SSM Parameter Store write (앱 시크릿 관리).

- 앱 설정값(DB URL, 외부 API 키 등)을 SSM에 기록
- `ephemeral` 리소스 + `_wo` suffix 패턴으로 state에 시크릿 미저장
- DB 비밀번호 등 민감값은 `SecureString` 타입으로 저장

## Global Resources

`terraform/global/` — 환경에 종속되지 않는 계정 수준 리소스:

- **GitHub OIDC Provider** — GitHub Actions ↔ AWS 인증 (장기 Access Key 미사용)
- **Deploy IAM Role** — ECR push + SSM SendCommand (전체 서비스 레포)
- **Terraform IAM Role** — 인프라 변경 (Cloud 레포 전용)
- **CDN Deploy Policy** — S3 upload + CloudFront invalidation
- **IAM Groups** — Admin (AdministratorAccess), 팀별 SSM 접근 제어 (cloud/be/fe/ai)
- **IAM Users** — Admin users, 팀 members, 서비스 계정 (grafana-billing-reader)
- **Budget Alert** — 50% / 80% / 100% threshold

## CI/CD

상세 설계와 현행 workflow 차이 분석은 [CICD.md](./CICD.md)를 기준으로 한다.

### Target GitHub Actions Structure

```
PR open  → detect changes → fmt/validate/security scan → plan comment + Infracost
main push → ordered apply with GitHub Environment approval
schedule → drift detection plan only
manual   → staging start/stop/scale/deploy/destroy
```

권장 workflow 파일:

| Workflow | Trigger | Responsibility |
|----------|---------|----------------|
| `terraform-pr.yml` | `pull_request` | 정적 검증, security scan, changed root module plan, PR comment, Infracost |
| `terraform-apply.yml` | `push` to `main`, `workflow_dispatch` | shared/env 레이어를 의존성 순서대로 apply |
| `terraform-drift.yml` | `schedule`, `workflow_dispatch` | 전체 root module drift plan, 알림만 수행 |
| `terraform-staging.yml` | `workflow_dispatch` | staging 수명주기 start/stop/scale/deploy/destroy |

### Apply Gates

- 배포 단위는 `modules/`가 아니라 state를 가진 root module이다.
- `dev`는 main merge 후 자동 apply 가능하다.
- `staging`은 manual workflow 또는 GitHub Environment approval을 둔다.
- `prod`와 shared/global 레이어는 GitHub Environment required reviewer를 필수로 둔다.
- 자동 apply에서 destroy 또는 replace가 포함되면 실패시키고, 삭제는 별도 수동 workflow에서만 수행한다.
- 같은 state key는 `concurrency`로 동시에 실행되지 않게 한다.
- AWS 인증은 GitHub OIDC + IAM Role assume만 사용하고 장기 access key는 사용하지 않는다.

### terraform-staging.yml (manual dispatch)

staging 환경 수명주기 관리. 위 [Staging Lifecycle](#staging-lifecycle) 참조.

## Security

### IAM
- OIDC 토큰 기반 인증 (장기 자격증명 미사용)
- Deploy / Terraform 역할 분리
- 팀별 SSM 접근 제어 (태그 기반 조건: Service, Environment)
- EC2 IAM Role: SSM + 해당 환경 S3/SSM Parameter/ECR만

### Network
- prod/staging: 앱 서버 프라이빗 서브넷 배치, nginx만 퍼블릭
- SG cross-rule: nginx → backend 방향만 허용 (SG 참조 기반)
- IMDSv2 강제 (`http_tokens = "required"`)
- EBS 전체 암호화

### Secrets
- DB password: `random_password` → SSM Parameter Store (SecureString)
- KMS key rotation 활성화
- `.tfvars` gitignore 처리

## Operational Notes

### Destroy 시 주의

- prod RDS는 `prevent_destroy` lifecycle — 삭제 시 `terraform state rm` 후 수동 삭제 필요
- staging RDS destroy는 workflow에서 자동으로 state rm 처리
- CI/CD auto-apply는 destroy를 차단한다. 삭제가 필요하면 수동 실행

### 모듈 변경 영향

`modules/` 변경 시 해당 모듈을 사용하는 **모든 환경**에 plan/apply가 실행된다. 변경 전 `./scripts/plan-all.sh`로 전체 영향 확인 권장.

### Drift 방지

- 모든 리소스에 `ManagedBy=Terraform` 태그 자동 부여
- 콘솔 수동 변경 금지. drift 발생 시 다음 apply에서 의도치 않은 덮어쓰기 발생
- `terraform state mv/rm`은 팀 공유 후 실행

### Naming Convention

```
{project}-{environment}-{resource}
```

예: `doktori-prod-vpc`, `doktori-staging-nginx-sg`, `doktori-dev-ec2-ssm`

## Known Limitations

- **Single AZ**: NAT Instance + RDS 모두 단일 AZ 배치 (비용 우선)
- **ECR prod-* repo 중복**: prod 전용 ECR repo가 별도로 존재 — 태그 기반 분리로 통합 예정
- **Terraform state 내 DB 비밀번호**: S3 암호화로 보완하나 완전한 해결은 아님
- **Terraform Role 권한**: EC2/RDS/S3에 `*` resource 사용 — 리소스 수준 제한 필요
- **모니터링 서버 네트워크**: mgmt 전용 VPC(172.16.0.0/16) 사용. dev/prod와는 VPC Peering 구성됨. staging은 peering 추가 전까지 VPN 경유 접근
