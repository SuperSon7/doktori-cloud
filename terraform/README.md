# Doktori — Terraform Infrastructure

dev / staging / prod 3개 환경의 AWS 인프라를 관리하는 Terraform 구성.

환경은 디렉토리 기반으로 완전 분리하고, 각 환경을 base / app / data 3계층으로 나누어 변경의 영향 범위를 최소화한다.

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
        │ NAT Instance│           │ NAT Instance│          │ NAT Instance│
        └──────┬──────┘           └──────┬──────┘          │+VPC Endpoint│
               │                    ┌────┴────┐            └──────┬──────┘
        ┌──────▼──────┐      ┌─────▼───┐ ┌───▼─────┐       ┌────┴────┐
        │   dev/app   │      │stg/app  │ │stg/data │  ┌────▼───┐ ┌──▼─────┐
        │ 2 instances │      │6 inst.  │ │  RDS    │  │prod/app│ │prod/dat│
        │ (all-in-one)│      │(micro)  │ │(dispos.)│  │6 inst. │ │  RDS   │
        └─────────────┘      └─────────┘ └─────────┘  └────────┘ └────────┘

        ┌─────────────┐      ┌─────────────┐      ┌─────────────┐
        │ monitoring/ │      │  dns-zone/  │      │ prod CDN    │
        │  (default   │      │  Route53 +  │      │ CloudFront  │
        │    VPC)     │      │  Google WS  │      │  + S3 OAC   │
        └─────────────┘      └─────────────┘      └─────────────┘
```

## Directory Structure

```
terraform/
├── backend.hcl                    # S3 backend 공통 설정
├── backend/                       # State backend 부트스트랩 (S3 + DynamoDB)
├── global/                        # 계정 수준 리소스 (OIDC, IAM, Budget)
├── modules/
│   ├── networking/                # VPC, Subnet, NAT Instance, VPC Endpoint
│   ├── compute/                   # EC2, SG, IAM Role, EIP
│   ├── database/                  # RDS, Parameter Group, DB Password (SSM)
│   └── storage/                   # S3, KMS, IAM (per-env)
├── ecr/                              # ECR repositories (cross-env)
├── environments/
│   ├── dev/
│   │   ├── base/                  # VPC (10.0.0.0/16)
│   │   └── app/                   # EC2 x2 (all-in-one)
│   ├── staging/
│   │   ├── base/                  # VPC (10.2.0.0/16)
│   │   ├── app/                   # EC2 x6 (service-per-instance)
│   │   ├── data/                  # RDS (disposable)
│   │   └── prod-spec.tfvars       # Prod-equivalent specs for load testing
│   └── prod/
│       ├── base/                  # VPC (10.1.0.0/16) + VPC Endpoints
│       ├── app/                   # EC2 x6 (service-per-instance)
│       ├── data/                  # RDS (protected)
│       └── cdn/                   # CloudFront + S3 static assets
├── monitoring/                    # Prometheus + Loki + Grafana (default VPC)
└── dns-zone/                      # Route53 Hosted Zone
```

## Prerequisites

- Terraform >= 1.0.0
- AWS CLI configured with appropriate IAM permissions
- Access to `doktori-v2-terraform-state` S3 bucket

## Quick Start

```bash
# Single layer
cd terraform/environments/prod/base
terraform init -backend-config=../../backend.hcl
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
backend → global → base → app → data
```

`base` must complete before `app`/`data` — they reference base outputs via `terraform_remote_state`.

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
| Backend | S3 (`doktori-v2-terraform-state`) |
| Locking | DynamoDB (`doktori-v2-terraform-locks`) |
| Encryption | AES-256 (S3 SSE) |
| Versioning | Enabled |

공통 backend 설정은 `backend.hcl`에 정의하고, 각 레이어의 `providers.tf`에서 state key만 지정한다.

```
# State key 구조
global/terraform.tfstate
{env}/base/terraform.tfstate
{env}/app/terraform.tfstate
{env}/data/terraform.tfstate
monitoring/terraform.tfstate
dns-zone/terraform.tfstate
ecr/terraform.tfstate
prod/cdn/terraform.tfstate
```

> `backend/` 디렉토리에서 state S3 bucket + DynamoDB table 자체를 Terraform으로 관리 (부트스트랩).

## Environment Comparison

| | dev | staging | prod |
|---|---|---|---|
| VPC CIDR | 10.0.0.0/16 | 10.2.0.0/16 | 10.1.0.0/16 |
| Instance layout | All-in-one x2 | Service-per-instance x6 | Service-per-instance x6 |
| App subnet | Public | Private (nginx: public) | Private (nginx: public) |
| VPC Endpoints | None | None | SSM, ECR, Logs (x6) |
| RDS | None (EC2 MySQL) | Disposable | Protected (GTID, 7d backup) |
| NAT | Ubuntu NAT Instance | Amazon Linux NAT Instance | Amazon Linux NAT Instance |

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

### terraform.yml (auto-apply)

```
PR open  → detect-changes → plan (PR comment) + Infracost (cost diff)
PR merge → detect-changes → apply-base → apply-app / apply-data
```

- 모듈 변경 시 전체 레이어 plan/apply, 개별 환경 변경 시 해당 레이어만
- **Auto-apply 시 destroy 차단**: plan에서 `will be destroyed` 감지 시 즉시 실패
- Infracost로 PR에 base 대비 비용 변동 코멘트
- Discord webhook 알림

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
- **모니터링 서버 네트워크**: dev/prod CIDR 충돌로 default VPC에 배치 (VPC 피어링 불가)
