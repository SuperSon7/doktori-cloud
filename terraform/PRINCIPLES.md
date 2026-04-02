# Terraform 구성 원칙

이 문서는 모든 Terraform 의사결정의 근거다.
예외 없이 적용하며, 예외가 필요하면 이 문서를 먼저 수정한다.

---

## 핵심 철학

1. **타당한 이유** -- 모든 결정에 "왜"가 있어야 한다. 이유 없는 리소스, 이유 없는 분리는 금지.
2. **효율** -- 불필요한 복잡도 없이 목적을 달성한다. 추상화는 정당한 이유가 있을 때만.
3. **느슨한 결합** -- 레이어 간 의존성 최소화. 하나를 바꿔도 다른 것에 영향 없어야 한다.
4. **안전한 생성과 파괴** -- 생성 순서대로 만들면 역순으로 안전하게 부순다. stateful은 보호.
5. **일관된 컨벤션** -- 태그, 네이밍, 디렉토리 구조 모두 하나의 규칙.
6. **교체 가능** -- CSP 종속, 도구 종속 최소화. 도구를 교체해도 구조가 유지되어야 한다.

---

## 1. 레이어 분리

기준은 **변경 빈도**와 **영향 범위(blast radius)** 두 축이다. 변경이 잦은데 영향 범위가 넓으면 설계 실패.

```
Layer 0: Bootstrap          -- S3 state bucket -- 1회성
Layer 1: Global             -- OIDC, IAM, Budget -- 계정 수준 정책
Layer 1: Shared/ECR         -- ECR repositories
Layer 1: Shared/DNS         -- dns_zone (Public Hosted Zone + 정적 레코드)
Layer 1: Shared/Monitoring  -- monitoring/base (SG, EIP, PHZ, Peering routes)
                            -- monitoring/data (S3 Loki)
                            -- monitoring/app  (EC2, IAM)
Layer 2: Foundation         -- {env}/base (VPC, NAT, Peering) -- 환경별 네트워크
Layer 3: Data               -- {env}/data (RDS) -- stateful
Layer 4: App                -- {env}/app (EC2, Lambda) -- stateless
```

- 레이어 분리 원칙은 예외 없이 적용한다. monitoring도 dev/prod와 동일하게 base/data/app으로 분리.
- Global(정책)과 Shared(인프라)는 같은 논리 계층이지만 성격이 다르므로 분리.
- 같은 계층이라도 state는 반드시 분리 (ecr, dns_zone, monitoring/base, monitoring/data, monitoring/app 각각 독립).

---

## 2. 의존성 규칙

**단방향 참조만 허용.** 상위 레이어가 하위를 참조하는 것은 금지.

```
App -> Data -> Foundation -> Shared/Global -> Bootstrap   (허용)
Bootstrap -> Global -> Shared -> Foundation -> App        (금지)
```

**참조 방식:** 용도에 따라 구분한다.

| 대상 | 수단 | 이유 |
|------|------|------|
| VPC ID, Subnet ID 등 인프라 식별자 | `terraform_remote_state` | 같은 레포/팀, 경로 안정적, AWS API 조회보다 빠름 |
| DB 비밀번호 등 앱 시크릿 | `ephemeral` + `_wo` + SSM | state에 평문 저장 방지, 앱이 런타임에 SSM에서 직접 읽음 |

```hcl
# 허용 — 인프라 식별자: remote_state로 직접 참조
data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = "doktori-terraform-state"
    key    = "dev/base/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
# 금지 — 레이어 간 인프라 참조에 AWS API 사용 (느리고, 태그 drift 시 실패)
data "aws_vpc" "main" {
  tags = { Name = "${var.project_name}-${var.environment}-vpc" }
}
```

하위 레이어에서 상위/동위 레이어의 리소스를 직접 생성, 수정, 삭제하지 않는다.

---

## 3. 리소스 배치 판단

아래 질문을 순서대로 적용한다:

1. 전체 계정에 영향? -> Global
2. 여러 환경이 공유? -> Shared
3. 특정 환경의 네트워크/기반? -> Foundation
4. 상태를 가지며 데이터 손실 위험? -> Data
5. 재생성해도 무방? -> App

IAM은 성격에 따라 배치가 달라진다:

| 종류 | 배치 레이어 | 이유 |
|------|-------------|------|
| OIDC provider, Role/User/Group 엔티티, Admin, Budget | Global | 계정 수준, 리소스 독립적 |
| 리소스에 종속된 policy attachment | 해당 리소스 레이어 | 참조 대상이 존재한 후 ARN 확정 |

**원칙:** Role 엔티티는 Global에서 생성한다. 특정 리소스 ARN(CloudFront distribution, KMS key, S3 bucket 등)을 참조하는 policy는 해당 리소스가 생성되는 레이어에서 `data "aws_iam_role"`로 role을 조회하여 `aws_iam_role_policy`로 attachment한다.

```hcl
# prod/cdn/main.tf — CDN 리소스가 있는 레이어에서 attachment
data "aws_iam_role" "gha_deploy" {
  name = "${var.project_name}-gha-deploy"
}
resource "aws_iam_role_policy" "gha_cdn" {
  role   = data.aws_iam_role.gha_deploy.id
  policy = jsonencode({ ... aws_cloudfront_distribution.cdn.arn 직접 참조 ... })
}
```

이 패턴은 HashiCorp Module Composition(Dependency Inversion), terraform-aws-modules, Gruntwork account-baseline 모두 동일하게 권장한다.

---

## 4. 네이밍 컨벤션

**AWS 리소스:** `{project}-{environment}-{resource}` (예: `doktori-dev-vpc`)

**State key:** `{environment}/{layer}/terraform.tfstate` (예: `dev/base/terraform.tfstate`)

**디렉토리:** `snake_case` 소문자 (예: `dns_zone`, `dev/base`)

**줄임말(약어):** 문서·주석·태그 값에서는 항상 대문자 사용 (ECR, IAM, DNS, VPC, RDS, ALB 등). Terraform 식별자(변수명·리소스 레이블)는 HCL 관례에 따라 소문자 snake_case (`vpc_id`, `ecr_repository`).

---

## 5. Apply / Destroy 순서

**Apply:**
```
backend → global → ecr → dns_zone → monitoring/base → monitoring/data → monitoring/app
→ {env}/base → monitoring re-apply (peering route 활성화) → {env}/data → {env}/app
```

**Destroy:** 생성의 정확한 역순. 특정 환경만 내릴 때는 `{env}/app → {env}/data → {env}/base`.
Shared destroy 전 모든 환경이 먼저 destroy되어야 한다.
monitoring destroy 순서: `monitoring/app → monitoring/data → monitoring/base`.

---

## 6. 태그 정책

태그는 비용 귀속, 리소스 식별, 자동화 제어에만 사용한다. 설정값을 태그에 넣지 않는다.

**default_tags** (provider 레벨, 자동 부여): `Project`, `Environment`, `ManagedBy=Terraform`

**리소스별 태그:**

| 태그 | 대상 | 용도 |
|------|------|------|
| `Name` | 모든 리소스 | 콘솔 식별, data source 조회 |
| `Service` | EC2, SG, LB, ECR | 서비스 구분, SSM 접근 제어 |
| `Owner` | EC2 | 담당 팀 식별 |
| `AutoStop` | EC2 | Lambda 자동 정지 대상 |
| `Schedule` | EC2 (batch) | 스케줄 기반 자동화 |

**규칙:** PascalCase만 사용. 설정값은 SSM Parameter Store로. 목록에 없는 태그 추가 시 팀 합의 필요.

---

## 7. State 관리

- Remote backend: S3 + `use_lockfile = true` (DynamoDB lock table 사용하지 않음)
- 모든 레이어는 독립된 state file을 가진다.
- `terraform state mv/rm`은 팀 공유 후 실행.
- 콘솔 수동 변경 금지. `ManagedBy=Terraform` 태그로 drift 식별.

**레이어 간 값 전달 방식:**

| 전달 대상 | 수단 | 이유 |
|-----------|------|------|
| VPC ID, Subnet ID 등 인프라 식별자 | `terraform_remote_state` | 동일 팀/레포, 경로 안정적, AWS API 조회 없이 빠름 |
| DB 비밀번호 등 앱 시크릿 | `ephemeral` + `_wo` + SSM Parameter Store | state에 평문 저장 방지, 앱이 런타임에 직접 읽음 |

```hcl
# 인프라 식별자: 상위 레이어 state에서 직접 참조
data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = "doktori-terraform-state"
    key    = "{env}/base/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# 앱 시크릿: Terraform은 생성 후 SSM에만 기록, state에 남기지 않음
resource "aws_db_instance" "main" {
  password_wo = aws_ssm_parameter.db_password.value  # _wo: state에 저장 안 됨
}
```

`Name` 태그 주석(`data source 조회`)은 remote_state 전환 후에도 콘솔 식별 용도로 유지한다.

---

## 8. Lifecycle 및 리소스 보호

**prevent_destroy:** stateful 리소스(S3, ECR, RDS)에 반드시 설정. 삭제 필요 시 코드에서 제거 후 PR 리뷰.

**create_before_destroy:** Security Group, IAM Policy 등 교체 시 다운타임 위험이 있는 리소스에 적용.

**ignore_changes:** 반드시 주석으로 이유를 명시. 이유 없는 ignore_changes는 drift 은폐이므로 금지.

```hcl
lifecycle {
  prevent_destroy = true                    # stateful 리소스 보호
  create_before_destroy = true              # SG 교체 시 다운타임 방지
  # ASG가 동적 조정하므로 Terraform이 덮어쓰면 안 됨
  ignore_changes = [desired_capacity]
}
```

---

## 9. 롤백 전략

**기본:** `git revert` + `terraform apply`. state 직접 조작은 최후의 수단.

**리팩토링:** `moved` 블록으로 리소스 보존. destroy + recreate 방지.

```hcl
moved {
  from = aws_instance.web
  to   = module.app.aws_instance.web
}
```

**안전장치 조합:** `prevent_destroy`(실수 삭제 방지) + `moved`(리팩토링 보존) + `git revert`(코드 롤백). 이 세 가지로 대부분의 롤백 시나리오를 처리한다.

---

## 10. 주석 정책

HCL은 선언적이므로 코드가 "what"을 설명한다. 주석은 "why"만 적는다. 한국어로 작성.

```hcl
# 허용: NAT Gateway 비용 절감을 위해 AZ 1개만 사용 (dev는 HA 불필요)
resource "aws_nat_gateway" "main" { ... }
# 금지: VPC를 생성한다
resource "aws_vpc" "main" { ... }
```

주석이 필요한 경우: `ignore_changes` 이유, 특정 값의 선택 근거, 비표준 배치의 이유, workaround.

---

## 11. CSP 이식성

완전한 CSP 독립은 비현실적이다. 불필요한 종속만 피한다.

- ARN 하드코딩 금지. data source나 리소스 속성으로 참조.
- AWS 계정 ID, 리전을 문자열로 하드코딩 금지. `data.aws_caller_identity`, `data.aws_region`으로 조회.
- 태그 기반 리소스 탐색을 기본으로 한다.
- 시크릿 관리: SSM Parameter Store를 사용하되, 접근 패턴을 추상화하여 교체 가능한 구조 유지.
- AWS managed service(VPC, S3, RDS, ECR, IAM)는 허용. 비즈니스 로직을 AWS API에 직접 결합하지 않는다.
