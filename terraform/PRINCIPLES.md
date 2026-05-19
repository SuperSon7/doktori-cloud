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
Layer 1: Shared/Monitoring  -- monitoring/base (mgmt VPC, NAT+WireGuard, PHZ, Peering routes)
                            -- monitoring/data (S3 Loki)
                            -- monitoring/app  (EC2, IAM, SG)
Layer 2: Foundation         -- {env}/base (VPC, NAT, Peering) -- 환경별 네트워크
Layer 3: Data               -- {env}/data (S3, RDS) -- stateful 스토리지. dev는 S3만 (RDS는 Docker Compose)
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
| EC2 instance role/profile | 해당 EC2 레이어 | EC2와 생명주기 동일, ARN이 EC2 생성 후 확정 |
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

**예외 — 서비스 주체(Service Principal) Role:** `codedeploy.amazonaws.com`, `lambda.amazonaws.com` 등 AWS 서비스가 assume하는 Role은 해당 리소스와 생명주기가 완전히 같으므로 리소스 레이어에서 함께 생성한다. Global에 두면 리소스 삭제 시 Role만 고아로 남고, 리소스 ARN 참조가 순환 의존을 만들기 때문이다.

```hcl
# prod/app/main.tf — CodeDeploy 서비스 Role은 app 레이어에서 직접 생성
resource "aws_iam_role" "frontend_codedeploy_service" {
  name = "${local.frontend_codedeploy_application_name}-service-role"
  assume_role_policy = jsonencode({
    Statement = [{ Principal = { Service = "codedeploy.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
```

---

## 4. 네이밍 컨벤션

**AWS 리소스:** `{project}-{environment}-{resource}` (예: `doktori-dev-vpc`)

Shared/Monitoring 리소스는 environment 자리에 역할명을 사용한다.

| 레이어 | environment 자리 | 예시 |
|--------|-----------------|------|
| dev/prod/staging | 환경명 | `doktori-dev-vpc` |
| monitoring 서비스 | `monitoring` | `doktori-monitoring-sg`, `doktori-monitoring-role` |
| mgmt 네트워크 | `mgmt` | `doktori-mgmt-vpc`, `doktori-mgmt-nat-sg` |

`mgmt`와 `monitoring`을 구분하는 이유: mgmt VPC는 WireGuard VPN 진입점과 모니터링 서버를 함께 호스팅하는 관리망이다. VPN은 모니터링과 무관하므로 네트워크 레이어는 `mgmt`, 그 위에 올라가는 모니터링 애플리케이션 리소스는 `monitoring`으로 구분한다.

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

**SSM Parameter Store 패턴:**

시크릿 성격에 따라 세 가지 패턴을 구분한다.

| 패턴 | 대상 | 코드 |
|------|------|------|
| **ephemeral + value_wo** | Terraform이 초기값 생성, 이후 변경 없음 (비밀번호 등 랜덤 가능) | 아래 예시 참고 |
| **CHANGE_ME 쉘** | 값을 CLI로 주입하는 파라미터 (외부 API key 등) | `ssm-parameters` 모듈 사용 |
| **Terraform 직접 write** | 코드에서 값이 확정되는 정적 파라미터 (포트 번호 등) | `ignore_changes` 없이 작성 |

```hcl
# 패턴 1 — ephemeral + value_wo: 초기 랜덤값 생성, state에 저장 안 됨
# random >= 3.7.0, AWS provider >= 5.78.0 필요
ephemeral "random_password" "api_key" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "api_key" {
  name             = "/${var.project_name}/${var.environment}/API_KEY"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.api_key.result
  value_wo_version = 1  # 키 로테이션 시 올린다

  lifecycle {
    # apply마다 새 랜덤 값이 생성되므로 생성 후 고정
    ignore_changes = [value_wo, value_wo_version]
  }
}

# 패턴 2 — CHANGE_ME 쉘: 값은 CLI로 주입, Terraform은 껍데기만 관리
# (ssm-parameters 모듈이 이 패턴을 공통화함)

# 패턴 3 — 정적 값: Terraform이 직접 write, ignore_changes 불필요
resource "aws_ssm_parameter" "rabbitmq_port" {
  name  = "/${var.project_name}/${var.environment}/SPRING_RABBITMQ_PORT"
  type  = "String"
  value = "5672"
  tags  = { Name = "${var.project_name}-${var.environment}-SPRING_RABBITMQ_PORT" }
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

### Security Group Description 원칙

Security Group은 **리소스 자체 description**과 **rule description**을 구분한다.

- `aws_security_group.description`: SG 리소스 자체 설명. AWS/Terraform에서 교체가 발생할 수 있으므로 운영 중인 고정 name SG에서는 함부로 변경하지 않는다.
- `ingress.description`, `egress.description`, `aws_vpc_security_group_*_rule.description`: 허용 규칙 설명. 실제 접근 경로를 명확히 하기 위해 적극적으로 관리한다.

Rule description 형식:

```text
from <source> to <target/service>
```

예:

```hcl
ingress {
  description = "from public ALB SG to k8s worker NGF NodePort"
  from_port   = 30080
  to_port     = 30080
  protocol    = "tcp"
}
```

금지/주의:

- SG 자체 description을 단순 문구 개선 목적으로 바꾸지 않는다.
- 고정 `name` + `create_before_destroy = true`인 SG의 자체 description을 바꾸면 Terraform이 같은 이름의 새 SG를 먼저 만들려다 `InvalidGroup.Duplicate`로 실패할 수 있다.
- description 정리 작업의 기본 범위는 rule description이다. SG 자체 description 변경이 꼭 필요하면 plan에서 `forces replacement` 여부를 확인하고, 별도 PR/작업으로 다룬다.

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

---

## 12. CI/CD 원칙

CI/CD의 배포 단위는 모듈이 아니라 독립 state를 가진 root module이다. `modules/`는 재사용 단위일 뿐 직접 apply 대상이 아니다.

**PR:** 검증과 plan만 수행한다. `terraform fmt -check`, `terraform validate`, 보안 스캔, 비용 diff, changed root module plan을 PR comment로 남긴다. PR에서 apply하지 않는다.

**Apply:** main merge 이후 실행하되 레이어 의존성 순서를 지킨다.

```
global → ecr/dns_zone → monitoring/base → monitoring/data → monitoring/app
→ {env}/base → monitoring re-apply → {env}/data → {env}/app → prod/cdn
```

같은 단계의 서로 다른 환경은 병렬 실행할 수 있다. 같은 state key를 만지는 job은 workflow가 달라도 `concurrency` group을 공유해야 한다.

**승인:** dev는 자동 apply 가능, staging은 manual 또는 approval, prod/shared/global은 GitHub Environment required reviewer를 요구한다.

**삭제:** 자동 apply에서 destroy/replace는 차단한다. 삭제는 별도 수동 workflow와 리뷰를 통해 실행한다.

**인증:** GitHub Actions는 OIDC로 AWS IAM Role을 assume한다. 장기 access key는 사용하지 않는다.

상세 workflow 설계와 현행 차이 분석은 `CICD.md`를 따른다.
