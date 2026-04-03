# Terraform 학습 가이드 — doktori 인프라 코드 기반

> 코드 위치는 직접 찾아 볼 것. 이 문서는 **왜 이 구조인가**에 집중한다.
> 각 질문의 답과 관련 개념은 토글로 접어두었다.

---

## 목차

1. [Provider & Backend — 가장 넓은 레벨](#1-provider--backend)
2. [프로젝트 디렉터리 구조](#2-프로젝트-디렉터리-구조)
3. [모듈 설계](#3-모듈-설계)
4. [변수 타입 시스템](#4-변수-타입-시스템)
5. [리소스 생성 패턴 — for_each / count / dynamic](#5-리소스-생성-패턴)
6. [Data Sources](#6-data-sources)
7. [State 관리 & 레이어 분리](#7-state-관리--레이어-분리)
8. [IAM & 보안 패턴](#8-iam--보안-패턴)
9. [네트워킹 구조](#9-네트워킹-구조)
10. [데이터베이스 패턴](#10-데이터베이스-패턴)
11. [Security Group 패턴](#11-security-group-패턴)
12. [Lifecycle 메타 인수](#12-lifecycle-메타-인수)
13. [환경별 설계 차이 (dev / staging / prod)](#13-환경별-설계-차이)
14. [moved 블록](#14-moved-블록)

---

## 1. Provider & Backend

---

### Q. `provider "aws"` 블록에 왜 `default_tags`를 쓰나요?

<details>
<summary>답 보기</summary>

```hcl
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
```

모든 `aws_*` 리소스에 자동으로 태그가 붙는다. 각 리소스 블록마다 `tags = { ... }`를 반복하지 않아도 된다.
비용 분석(Cost Explorer), 리소스 검색, IAM 조건(`ec2:ResourceTag/...`)에 태그가 필수적이기 때문이다.

**빠진 태그 하나가 Cost Explorer를 망친다.** default_tags는 이를 강제로 방지한다.

</details>

<details>
<summary>관련 개념 — AWS 태그 전략</summary>

- **태그 기반 IAM**: `Condition: StringEquals: ec2:ResourceTag/Service: batch-weekly` → 특정 태그가 붙은 EC2만 StopInstances 허용
- **Cost Allocation Tags**: AWS 콘솔에서 활성화하면 Project/Environment 기준으로 비용 분리 가능
- **Resource Groups**: 태그로 리소스를 논리적으로 묶어 일괄 관리
- `default_tags`와 리소스 자체 `tags`가 동시에 있으면 **리소스 tags가 우선**하여 merge된다

</details>

---

### Q. 왜 `required_version`과 `required_providers`를 명시하나요?

<details>
<summary>답 보기</summary>

```hcl
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

`~> 5.0`은 "5.x는 허용하되 6.0은 허용하지 않음"을 의미하는 pessimistic constraint operator다.
명시하지 않으면 팀원마다 다른 버전을 쓰게 되고, provider 마이너 업데이트에서 breaking change가 생기면 CI는 깨지는데 로컬은 통과하는 상황이 발생한다.

</details>

<details>
<summary>관련 개념 — 버전 제약 문법</summary>

| 표기 | 의미 |
|------|------|
| `= 5.0.0` | 정확히 이 버전만 |
| `>= 5.0` | 5.0 이상 모두 |
| `~> 5.0` | 5.0 이상 6.0 미만 (마지막 자리만 올라감) |
| `~> 5.47.0` | 5.47.x만 허용 |
| `>= 5.0, < 5.50` | 범위 지정 |

`terraform.lock.hcl`이 실제로 설치된 버전을 고정한다. `required_providers`는 허용 범위, lock 파일은 실제 버전이다.

</details>

---

### Q. 왜 state를 S3에 저장하나요? 로컬에 저장하면 안 되나요?

<details>
<summary>답 보기</summary>

```hcl
backend "s3" {
  bucket = "doktori-terraform-state"
  key    = "environments/prod/base/terraform.tfstate"
  region = "ap-northeast-2"
}
```

`terraform.tfstate`는 현재 인프라 상태를 담은 JSON 파일이다. 로컬에 두면:
1. **협업 불가** — 다른 팀원이 apply하면 state가 충돌
2. **분실 위험** — 로컬 파일 삭제 시 Terraform이 리소스 존재를 모름 → 다음 apply에서 중복 생성 시도
3. **lock 없음** — 두 사람이 동시에 apply하면 state가 망가짐

S3 + DynamoDB lock을 쓰면 atomic lock으로 동시 apply를 방지한다.

이 프로젝트는 팀 규모가 작아 DynamoDB lock은 생략했지만, S3 versioning을 켜서 state 파일 이력은 보존한다.

</details>

<details>
<summary>관련 개념 — terraform.tfstate 구조</summary>

state 파일은 **Terraform이 관리하는 리소스의 현실 세계 매핑**이다.

```json
{
  "resources": [{
    "type": "aws_instance",
    "name": "this",
    "instances": [{
      "attributes": {
        "id": "i-0abc123",
        "instance_type": "t4g.large",
        ...
      }
    }]
  }]
}
```

- `terraform plan`은 state(현재)와 코드(원하는 상태)를 비교해 diff를 만든다
- `terraform import`는 이미 존재하는 리소스를 state에 등록한다
- state를 직접 수정하려면 `terraform state mv`, `terraform state rm`을 쓴다

</details>

---

## 2. 프로젝트 디렉터리 구조

---

### Q. 왜 `backend / global / ecr / environments / modules`로 나눴나요?

<details>
<summary>답 보기</summary>

```
terraform/
├── backend/          ← state 저장소 자체를 Terraform으로 만듦
├── global/           ← AWS 계정 1번만 만드는 것들 (OIDC, IAM 그룹, 예산)
├── ecr/              ← 공유 컨테이너 레지스트리
├── dns_zone/         ← 공유 Route53 퍼블릭 존
├── modules/          ← 재사용 가능한 블록
└── environments/
    ├── dev/
    ├── staging/
    └── prod/
```

**변경 빈도와 영향 범위**로 나눈 것이다.

| 레이어 | 변경 빈도 | 영향 범위 |
|--------|----------|----------|
| backend | 거의 없음 | 모든 레이어 |
| global | 낮음 | 계정 전체 |
| shared (ecr, dns) | 낮음 | 모든 환경 |
| environments/base | 중간 | 해당 환경 전체 |
| environments/app | 높음 | 해당 환경 앱만 |

base를 바꾸면 VPC ID가 바뀔 수 있어 app도 재배포해야 한다.
반대로 app을 아무리 바꿔도 base는 영향 없다. 레이어가 없으면 작은 코드 변경도 전체 plan을 실행해야 한다.

</details>

<details>
<summary>관련 개념 — Terraform root module vs child module</summary>

- **root module**: `terraform init/plan/apply`를 직접 실행하는 디렉터리. `backend "s3" {}` 블록이 있는 곳
- **child module**: `source = "../../../modules/networking"` 으로 호출되는 모듈. 자체 state가 없다
- 이 프로젝트에서 `environments/dev/base/`, `environments/prod/app/` 등이 각각 독립적인 root module이다
- 각 root module마다 별도 `terraform.tfstate` 파일이 S3에 저장된다

</details>

---

### Q. 왜 `base → data → app` 순서로 레이어를 나눴나요?

<details>
<summary>답 보기</summary>

단방향 의존성을 강제하기 위해서다.

```
base (VPC, 서브넷)
  ↓
data (RDS — VPC ID, subnet ID 필요)
  ↓
app (EC2 — VPC ID, subnet ID, RDS endpoint 필요)
```

app에서 base의 VPC ID가 필요하다면, base를 먼저 apply해야 한다.
레이어를 나누지 않으면 하나의 거대한 state 파일이 되고:
1. plan 속도가 느려진다
2. 한 리소스 변경이 전체 plan에 영향을 준다
3. 팀원 간 apply 순서가 꼬인다

</details>

---

## 3. 모듈 설계

---

### Q. modules/networking 같은 모듈은 왜 만드나요? 환경별로 그냥 복붙하면 안 되나요?

<details>
<summary>답 보기</summary>

복붙하면:
- dev/staging/prod 세 곳을 모두 수정해야 할 때 한 곳을 빠뜨리는 실수가 생긴다
- 보안 패치(예: NAT SG에 규칙 추가)를 모든 환경에 일관되게 적용하기 어렵다

모듈을 쓰면:
- **공통 로직은 한 곳에서 관리**하고, 환경별 차이는 변수로 주입한다
- `nat_instance_type = "t4g.micro"` (dev) vs `nat_instance_type = "t4g.small"` (prod) 처럼

```hcl
# dev/base/main.tf
module "networking" {
  source            = "../../../modules/networking"
  nat_instance_type = "t4g.micro"      # dev는 작게
}

# prod/base/main.tf
module "networking" {
  source            = "../../../modules/networking"
  nat_instances = {
    primary   = { subnet_key = "public" }
    secondary = { subnet_key = "public_c" }  # prod는 HA
  }
}
```

</details>

<details>
<summary>관련 개념 — 모듈 호출 문법</summary>

```hcl
module "이름" {
  source = "경로 or 레지스트리 주소"

  # 모듈의 variable에 값을 주입
  project_name = var.project_name
  vpc_cidr     = "10.0.0.0/16"
}

# 모듈의 output을 참조하는 방법
resource "aws_route" "example" {
  vpc_peering_connection_id = aws_vpc_peering_connection.main.id
  # 모듈 output 참조: module.모듈이름.output이름
  route_table_id = module.networking.public_route_table_id
}
```

- `source`에는 로컬 경로(`../../../modules/networking`), Git URL, Terraform Registry 주소가 올 수 있다
- 모듈 내부에서 `output`으로 노출한 값만 외부에서 `module.xxx.yyy`로 참조 가능하다

</details>

---

### Q. 모듈의 `outputs.tf`는 왜 필요한가요?

<details>
<summary>답 보기</summary>

모듈 내부에서 만든 리소스의 ID/ARN 등을 **호출자(상위 레이어)에게 전달**하기 위해서다.

```hcl
# modules/networking/outputs.tf
output "vpc_id" {
  value = aws_vpc.main.id
}
output "subnet_ids" {
  value = { for k, v in aws_subnet.this : k => v.id }
}

# environments/dev/app/main.tf — base의 output을 data source로 조회
data "aws_vpc" "main" {
  tags = { Environment = var.environment, Project = var.project_name }
}
```

output이 없으면 모듈 내부의 `aws_vpc.main.id` 같은 값을 외부에서 직접 참조할 수 없다. (Terraform은 모듈 경계를 엄격히 분리한다.)

</details>

---

## 4. 변수 타입 시스템

---

### Q. `variable` 블록에 `type = map(object({...}))`처럼 복잡한 타입을 쓰는 이유는?

<details>
<summary>답 보기</summary>

`services` 변수를 보면:
```hcl
variable "services" {
  type = map(object({
    instance_type = string
    architecture  = string
    subnet_key    = string
    volume_size   = optional(number, 20)
    sg_ingress    = list(object({
      from_port   = number
      to_port     = number
      protocol    = string
      cidr_blocks = optional(list(string), [])
    }))
  }))
}
```

타입을 명시하면:
1. **잘못된 값을 plan 단계에서 차단** — `instance_type = 123` 처럼 숫자를 넣으면 에러
2. **IDE 자동완성** 지원
3. **문서화** — 변수만 봐도 어떤 구조인지 알 수 있다

타입을 `any`로 두면 런타임 에러가 apply 중에 터진다. 복잡한 구조일수록 타입을 명시하는 게 이득이다.

</details>

<details>
<summary>관련 개념 — Terraform 타입 시스템</summary>

**기본 타입**
| 타입 | 예시 |
|------|------|
| `string` | `"ap-northeast-2"` |
| `number` | `20`, `3.14` |
| `bool` | `true`, `false` |

**컬렉션 타입**
| 타입 | 특징 |
|------|------|
| `list(string)` | 순서 있음, 중복 허용. 인덱스로 접근: `var.list[0]` |
| `set(string)` | 순서 없음, 중복 불허. `toset()`으로 변환 |
| `map(string)` | key-value. `var.map["key"]`로 접근 |
| `object({...})` | 정해진 속성명과 타입을 가진 구조체 |
| `tuple([string, number])` | 순서 있고 각 요소 타입이 다른 리스트 |

**any**: 타입 검사 생략. 가능하면 쓰지 않는다.

</details>

---

### Q. `optional(number, 20)` 문법은 뭔가요?

<details>
<summary>답 보기</summary>

```hcl
volume_size = optional(number, 20)
```

`optional(타입, 기본값)` — 이 필드를 **안 넘겨도 된다**는 뜻이다. 안 넘기면 기본값 20이 사용된다.

Terraform 1.3+에서 추가된 문법이다. 이전에는 `variable`에서 `default`로만 기본값을 설정할 수 있었는데, `object` 내부의 개별 필드에는 쓸 수 없었다. `optional()`이 이 문제를 해결한다.

```hcl
# volume_size 안 넘겨도 됨
services = {
  app = {
    instance_type = "t4g.large"
    architecture  = "arm64"
    subnet_key    = "private_app"
    # volume_size 생략 → 20 사용
    sg_ingress = []
  }
}
```

</details>

---

### Q. `locals` 블록을 왜 쓰나요?

<details>
<summary>답 보기</summary>

반복 표현식이나 중간 계산 결과를 변수처럼 재사용하기 위해서다.

```hcl
locals {
  # NAT 인스턴스가 없으면 기본값으로 단일 NAT 생성
  nat_instances = var.nat_instances != null ? var.nat_instances : {
    primary = { subnet_key = var.nat_subnet_key }
  }

  # 각 서브넷이 어떤 NAT를 써야 하는지 계산
  subnet_nat_key = {
    for k, v in var.subnets : k =>
      v.tier == "public" ? null :
      contains(keys(local.nat_instances), v.az_key) ? v.az_key : "primary"
  }
}
```

`locals`는:
- `variable`과 달리 **외부에서 값을 주입받지 않는다** — 모듈 내부 전용
- `output`과 달리 **외부에 노출되지 않는다**
- 같은 표현식을 여러 곳에서 쓸 때 한 번만 정의하면 된다

</details>

---

## 5. 리소스 생성 패턴

---

### Q. `for_each`와 `count`의 차이는? 왜 서브넷에 `for_each`를 썼나요?

<details>
<summary>답 보기</summary>

```hcl
# for_each 사용 — 서브넷
resource "aws_subnet" "this" {
  for_each = var.subnets   # map을 넘김

  cidr_block = each.value.cidr
  # 리소스 주소: aws_subnet.this["public"], aws_subnet.this["private_app"]
}

# count 사용 예시 (이 프로젝트에서 count는 조건부 생성에 주로 사용)
resource "aws_iam_role" "nat" {
  count = var.nat_iam_instance_profile == "" ? 1 : 0
  # 리소스 주소: aws_iam_role.nat[0]
}
```

**핵심 차이:**

| | `for_each` | `count` |
|--|------------|---------|
| 입력 | map 또는 set | number |
| 리소스 주소 | `resource["key"]` | `resource[0]` |
| 중간 삭제 | 해당 key만 삭제 | 인덱스 뒤의 모든 리소스가 재생성 |

서브넷에 `count = 3`을 쓰면 `private_app` 서브넷을 삭제할 때 `[1]`이 `[2]`로 바뀌면서 전체가 재생성된다. `for_each`를 쓰면 `"private_app"` key만 삭제되고 나머지는 그대로다.

**결론:** 리소스에 의미 있는 이름(key)이 있으면 `for_each`. 단순 개수로 제어하면 `count`. 조건부 생성(0 또는 1)에는 `count = var.enable ? 1 : 0`.

</details>

<details>
<summary>관련 개념 — for_each의 each 객체</summary>

```hcl
resource "aws_subnet" "this" {
  for_each = var.subnets

  # each.key → map의 키: "public", "private_app", "private_db"
  # each.value → map의 값: { cidr = "...", tier = "...", az_key = "..." }

  cidr_block = each.value.cidr
  tags = {
    Name = "${var.project_name}-${replace(each.key, "_", "-")}"
    # replace("private_app", "_", "-") → "private-app"
  }
}

# for_each로 만든 리소스를 다른 곳에서 참조할 때
output "subnet_ids" {
  value = { for k, v in aws_subnet.this : k => v.id }
  # { "public" = "subnet-abc", "private_app" = "subnet-def", ... }
}
```

</details>

---

### Q. `dynamic` 블록은 왜 쓰나요?

<details>
<summary>답 보기</summary>

리소스 내부의 **반복되는 중첩 블록**을 동적으로 생성할 때 쓴다.

```hcl
# dynamic 없이: ingress 규칙 개수만큼 블록을 하드코딩해야 함
resource "aws_security_group" "nat" {
  ingress { from_port = 22 ... }
  ingress { from_port = 80 ... }
  ingress { from_port = 443 ... }
}

# dynamic 사용: 변수로 개수를 조절할 수 있음
resource "aws_security_group" "nat" {
  ingress {
    # 기본 규칙 (VPC 전체 허용)
    cidr_blocks = [var.vpc_cidr]
    ...
  }

  dynamic "ingress" {
    for_each = var.nat_extra_ingress  # 추가 규칙 목록
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
    }
  }
}
```

dev의 NAT에는 WireGuard(UDP 51820) 규칙이 추가된다. 모듈은 공통이지만 추가 규칙은 `nat_extra_ingress` 변수로 주입한다.

`dynamic` 블록의 iterator 이름(기본값: 블록 이름)을 바꾸려면 `iterator = my_iter`를 쓴다.

</details>

---

### Q. `for` 표현식은 어디에 쓰이나요?

<details>
<summary>답 보기</summary>

리스트나 맵을 **변환**할 때 쓴다.

```hcl
# 1. list → list 변환
flatten([
  for arn in var.s3_bucket_arns : [arn, "${arn}/*"]
])
# ["arn:aws:s3:::bucket", "arn:aws:s3:::bucket/*", ...]

# 2. map → map 변환 (subnet_ids output)
{ for k, v in aws_subnet.this : k => v.id }
# { "public" = "subnet-abc", "private_app" = "subnet-def" }

# 3. map → list (for_each를 위한 변환)
{
  for rule in var.sg_cross_rules :
  "${rule.service_key}-from-${rule.source_key}-${rule.from_port}" => rule
}
# key를 직접 만들어서 for_each에 넣을 수 있는 map으로 변환

# 4. 조건 필터링
{
  for k, v in var.services : k => v
  if v.associate_eip && v.existing_eip_allocation_id == ""
}
# associate_eip = true이고 기존 EIP가 없는 서비스만 필터링
```

</details>

---

### Q. `templatefile()` 함수는 왜 쓰나요?

<details>
<summary>답 보기</summary>

EC2 `user_data`처럼 **긴 스크립트에 Terraform 변수를 주입**할 때 쓴다.

```hcl
# .tftpl 파일: 쉘 스크립트에 ${변수명} 자리표시자
# templates/dev_ai_batch_user_data.sh.tftpl
#!/bin/bash
aws ecr get-login-password --region ${aws_region} | docker login ...
docker pull ${image_uri}
aws ssm get-parameter --name "${ssm_parameter_path}/AI_API_KEY" ...

# main.tf에서 호출
batch_user_data = templatefile(
  "${path.module}/templates/dev_ai_batch_user_data.sh.tftpl",
  {
    aws_region         = var.aws_region
    image_uri          = local.batch_image_uri
    ssm_parameter_path = var.batch_ssm_parameter_path
  }
)
```

`heredoc(<<-EOF)`으로 인라인 작성하면 스크립트가 길어질수록 main.tf가 지저분해진다. `.tftpl` 파일로 분리하면 스크립트 자체에 집중할 수 있다.

</details>

---

## 6. Data Sources

---

### Q. `data "aws_ami"` 블록은 뭔가요? 왜 filter를 두 개 쓰나요?

<details>
<summary>답 보기</summary>

```hcl
data "aws_ami" "nat_ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical (Ubuntu 공식 계정 ID)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
```

`data` 블록은 **이미 존재하는 것을 조회**한다. AMI는 Terraform이 만드는 게 아니라 AWS가 제공하는 것이므로 `data`로 가져온다.

`filter`를 두 개 쓰는 이유: AMI 이름 패턴만으로는 여러 개가 걸릴 수 있다. `virtualization-type = "hvm"`을 추가해 PV(반가상화) 방식의 구형 AMI를 제외한다. `most_recent = true`로 그 중 최신 것을 하나 선택한다.

`099720109477`은 Canonical의 AWS 계정 ID다. 이걸 지정하지 않으면 마켓플레이스의 다른 Ubuntu AMI(악성 AMI 포함)가 걸릴 수 있다.

</details>

<details>
<summary>관련 개념 — resource vs data</summary>

```hcl
# resource: Terraform이 만들고 관리함 (state에 등록됨)
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# data: 이미 있는 것을 읽어옴 (state에 영향 없음)
data "aws_vpc" "mgmt" {
  default = true  # 기본 VPC 조회
}

# 참조 방법
resource "aws_vpc_peering_connection" "example" {
  vpc_id      = aws_vpc.main.id        # resource 참조
  peer_vpc_id = data.aws_vpc.mgmt.id   # data 참조
}
```

data source로 가져온 값은 `data.타입.이름.속성` 형태로 참조한다.

</details>

---

### Q. `data "aws_vpc" "mgmt" { default = true }` — 왜 이렇게 monitoring VPC를 찾나요?

<details>
<summary>답 보기</summary>

```hcl
# prod/base/main.tf
data "aws_vpc" "mgmt" {
  default = true  # 계정의 기본 VPC (172.31.0.0/16)
}
```

monitoring 인프라가 AWS 계정의 **default VPC**에 올라가 있기 때문이다. default VPC는 각 리전에 자동으로 생성되는 VPC로, 특별한 태그 없이도 `default = true`로 찾을 수 있다.

dev/base에서는 `data "terraform_remote_state" "monitoring_base"`로 monitoring의 state 파일을 직접 읽는 방식을 쓴다. 두 방식 모두 외부 리소스를 참조하지만, **AWS data source가 더 안전**하다 — state 파일 경로가 바뀌어도 영향을 안 받는다.

프로젝트 PRINCIPLES에서 "terraform_remote_state 사용 금지"를 원칙으로 삼은 이유도 이것이다.

</details>

---

## 7. State 관리 & 레이어 분리

---

### Q. 왜 `terraform_remote_state` 대신 AWS data source로 다른 레이어를 참조하나요?

<details>
<summary>답 보기</summary>

```hcl
# 나쁜 예 — terraform_remote_state
data "terraform_remote_state" "base" {
  backend = "s3"
  config  = { bucket = "doktori-terraform-state", key = "prod/base/terraform.tfstate" }
}
vpc_id = data.terraform_remote_state.base.outputs.vpc_id  # state 파일 구조에 강결합

# 좋은 예 — AWS data source
data "aws_vpc" "main" {
  tags = { Project = var.project_name, Environment = var.environment }
}
vpc_id = data.aws_vpc.main.id  # AWS API 조회 → state 구조와 무관
```

`terraform_remote_state`의 문제:
1. **강결합** — base의 output 이름을 바꾸면 app도 함께 수정해야 함
2. **읽기 권한** — app 레이어에 base state 파일의 S3 읽기 권한이 필요
3. **민감 정보** — state 파일에는 비밀번호 등 민감 데이터가 있을 수 있음

AWS data source는 **AWS API를 직접 호출**하므로 다른 팀의 state 구조와 독립적이다.

</details>

---

### Q. 각 레이어마다 `terraform init`을 새로 해야 하나요?

<details>
<summary>답 보기</summary>

그렇다. 각 `environments/dev/base/`, `environments/dev/app/` 등은 **독립적인 root module**이다.

```bash
cd terraform/environments/dev/base
terraform init   # .terraform/ 디렉터리 생성, provider 다운로드
terraform plan
terraform apply

cd ../app
terraform init   # 별도 init 필요
terraform plan
terraform apply
```

`terraform init`은:
1. `backend "s3"` 설정으로 remote state 연결
2. `required_providers`의 provider 바이너리 다운로드
3. `source = "../../../modules/networking"` 모듈 로드

각 디렉터리마다 `.terraform/` 폴더가 생기는 이유도 이것이다.

</details>

---

## 8. IAM & 보안 패턴

---

### Q. EC2에 IAM role을 왜 붙이나요? 직접 Access Key를 넣으면 안 되나요?

<details>
<summary>답 보기</summary>

```hcl
resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${var.project_name}-${var.environment}-ec2-ssm"
  role = aws_iam_role.ec2_ssm.name
}

resource "aws_instance" "this" {
  iam_instance_profile = aws_iam_instance_profile.ec2_ssm.name
}
```

EC2에 IAM role을 붙이면 인스턴스가 **임시 자격증명**을 자동으로 갱신한다. `aws s3 cp` 같은 명령이 Access Key 없이 작동한다.

Access Key를 직접 넣으면:
- 키를 코드에 커밋하는 실수가 생긴다
- 키가 유출되면 교체하는 작업이 크다
- 90일마다 수동으로 로테이션해야 한다

IAM role의 임시 자격증명은 1시간 단위로 자동 갱신된다.

</details>

<details>
<summary>관련 개념 — IAM Role의 3가지 구성요소</summary>

```hcl
# 1. Role 자체 — "누가 이 역할을 맡을 수 있나?" (trust policy)
resource "aws_iam_role" "ec2_ssm" {
  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }  # EC2 서비스만 assume 가능
      Action    = "sts:AssumeRole"
    }]
  })
}

# 2. Policy 연결 — "이 역할이 뭘 할 수 있나?" (permission policy)
resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 3. Instance Profile — EC2에 Role을 연결하기 위한 래퍼
resource "aws_iam_instance_profile" "ec2_ssm" {
  role = aws_iam_role.ec2_ssm.name
}
```

EC2는 직접 role을 받지 않고 **instance profile**을 통해 받는다. (IAM Role 자체는 EC2 전용이 아니라 Lambda, ECS 등에도 쓰이기 때문에 profile이 EC2용 래퍼 역할을 한다.)

</details>

---

### Q. GitHub Actions에서 OIDC로 AWS 인증하는 게 뭔가요?

<details>
<summary>답 보기</summary>

```hcl
resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions_deploy" {
  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = local.github_oidc_subjects
          # "repo:100-hours-a-week/5-team-service-be:ref:refs/heads/main"
        }
      }
    }]
  })
}
```

**흐름:**
1. GitHub Actions 워크플로우가 실행될 때 GitHub이 JWT 토큰 발급
2. AWS가 해당 JWT를 OIDC provider로 검증
3. 검증 통과 시 `sts:AssumeRoleWithWebIdentity`로 임시 자격증명 교환
4. 이후 일반 AWS CLI/SDK 명령 사용 가능

**장점:** AWS Access Key를 GitHub Secrets에 저장할 필요가 없다. 토큰은 워크플로우 실행 시간 동안만 유효하다. `ref:refs/heads/main` 조건으로 main 브랜치 워크플로우만 허용 가능.

</details>

---

### Q. `metadata_options { http_tokens = "required" }`는 왜 넣나요?

<details>
<summary>답 보기</summary>

```hcl
metadata_options {
  http_tokens                 = "required"   # IMDSv2 강제
  http_endpoint               = "enabled"
  http_put_response_hop_limit = 2            # 컨테이너 안에서도 접근 가능
}
```

EC2 인스턴스는 `http://169.254.169.254/latest/meta-data/`로 자신의 메타데이터(IAM 자격증명 포함)를 조회할 수 있다.

**IMDSv1** (구버전): HTTP GET 요청만으로 바로 조회 가능 → SSRF 공격에 취약
**IMDSv2** (`http_tokens = "required"`): 먼저 세션 토큰을 발급받아야 조회 가능 → SSRF 방어

AWS Capital One 해킹 사고(2019)가 IMDSv1 SSRF 취약점으로 발생했다. 이후 AWS는 IMDSv2를 강력히 권고한다.

`hop_limit = 2`는 Docker 컨테이너 안에서 메타데이터에 접근할 때 필요하다 (컨테이너 → 호스트 hop 추가).

</details>

---

## 9. 네트워킹 구조

---

### Q. NAT Gateway 대신 NAT Instance를 쓴 이유는?

<details>
<summary>답 보기</summary>

```hcl
resource "aws_instance" "nat" {
  instance_type     = var.nat_instance_type  # t4g.nano (dev), t4g.small (prod)
  source_dest_check = false  # 이게 있어야 NAT 동작
  user_data = <<-EOF
    #!/bin/bash
    sysctl -w net.ipv4.ip_forward=1
    iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE
  EOF
}
```

**비용 비교 (ap-northeast-2 기준, 2024):**

| | NAT Gateway | NAT Instance (t4g.small) |
|--|-------------|--------------------------|
| 고정 비용 | $0.059/시간 (~$43/월) | $0.0084/시간 (~$6/월) |
| 데이터 전송 | $0.059/GB | 일반 EC2 요금 |

NAT Gateway가 편하지만 비용이 7배 이상 비싸다. 스타트업/팀 프로젝트에서 비용이 핵심 제약이면 NAT Instance가 합리적이다.

**NAT Instance의 단점:**
- 직접 고가용성 구성해야 함 (prod는 AZ별 2개 운용)
- EC2 장애 시 수동 개입 필요
- 처리량이 인스턴스 타입에 제한됨

</details>

<details>
<summary>관련 개념 — source_dest_check = false</summary>

EC2는 기본적으로 **자신이 source 또는 destination인 패킷만 처리**한다. 다른 IP의 패킷이 들어오면 버린다.

NAT는 private 서브넷의 EC2(예: 10.0.16.5) → 인터넷으로 가는 패킷을 대신 포워딩해야 한다. 이 패킷의 source는 NAT 인스턴스 IP가 아니므로, source/destination check를 끄지 않으면 버려진다.

`source_dest_check = false` → "내가 source나 destination이 아닌 패킷도 처리하겠다"

라우터/NAT 역할을 하는 EC2에만 필요한 설정이다.

</details>

---

### Q. VPC Endpoint (Interface vs Gateway)의 차이는? 왜 prod에만 있나요?

<details>
<summary>답 보기</summary>

```hcl
# Interface Endpoint — ENI를 통해 AWS 서비스에 직접 연결
resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(var.vpc_interface_endpoints)
  # ["ssm", "ssmmessages", "ec2messages", "ecr.api", "ecr.dkr", "logs"]
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true  # 기존 서비스 DNS 주소 그대로 사용 가능
}

# Gateway Endpoint — 라우팅 테이블에 S3/DynamoDB 경로 추가
resource "aws_vpc_endpoint" "s3" {
  vpc_endpoint_type = "Gateway"
  # 모든 환경에서 사용
}
```

| | Interface Endpoint | Gateway Endpoint |
|--|-------------------|-----------------|
| 동작 방식 | ENI (프라이빗 IP 부여) | 라우팅 테이블 항목 추가 |
| 비용 | 시간당 요금 + 데이터 요금 | **무료** |
| 지원 서비스 | SSM, ECR, CloudWatch 등 | S3, DynamoDB만 |

**dev에 Interface Endpoint가 없는 이유:** NAT Instance를 통해 인터넷으로 AWS API에 접근하면 된다. Interface Endpoint는 1개당 월 ~$7이므로 6개면 $42 추가된다. dev는 비용 절감 우선.

**prod에 필요한 이유:** ECR pull 트래픽이 많을 때 NAT를 거치면 데이터 전송 비용이 발생한다. VPC Endpoint를 쓰면 AWS 내부 경로로 트래픽이 이동해 비용 절감 + 보안 강화.

</details>

---

### Q. Route Table에 `lifecycle { ignore_changes = [route] }`를 쓴 이유는?

<details>
<summary>답 보기</summary>

```hcl
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  lifecycle {
    ignore_changes = [route]  # route 변경 감지 무시
  }
}
```

VPC peering 라우트는 별도 `aws_route` 리소스로 추가된다:
```hcl
resource "aws_route" "dev_public_to_mgmt" {
  route_table_id         = module.networking.public_route_table_id
  destination_cidr_block = local.mgmt_vpc_cidr
  ...
}
```

만약 `ignore_changes`가 없으면, `aws_route_table` 리소스가 자신이 모르는 route(`aws_route`로 추가된 것)를 발견하고 다음 plan에서 "이 route를 삭제하겠다"고 출력한다. `ignore_changes = [route]`로 이 충돌을 방지한다.

**inline rule vs separate resource 충돌**: SG의 `ingress` 블록과 `aws_security_group_rule` 리소스를 동시에 쓸 때도 같은 문제가 생긴다. 이 프로젝트의 cross-rule이 별도 `aws_security_group_rule`로 분리된 이유도 동일하다.

</details>

---

### Q. Public/Private Route Table을 왜 나눠야 하나요?

<details>
<summary>답 보기</summary>

라우팅은 서브넷의 인터넷 접근 방식을 결정한다.

```
[Public Subnet] → aws_route_table.public
  기본 경로 (0.0.0.0/0) → Internet Gateway (IGW)
  → 인터넷 직접 통신 가능

[Private Subnet] → aws_route_table.private
  기본 경로 (0.0.0.0/0) → NAT Instance (ENI)
  → NAT를 통해 아웃바운드만 가능, 외부에서 직접 접근 불가
```

이 분리가 없으면 private 서브넷의 EC2도 Public IP만 있으면 인터넷에서 직접 접근 가능해진다. 데이터베이스, 앱 서버를 private 서브넷에 두는 것이 보안 기본이다.

prod에서는 AZ별로 private route table이 2개다 (`private["primary"]`, `private["secondary"]`). 각 AZ의 private 서브넷이 해당 AZ의 NAT로 라우팅되어 AZ 장애 시 cross-AZ 트래픽 비용을 줄인다.

</details>

---

## 10. 데이터베이스 패턴

---

### Q. RDS 비밀번호를 `random_password`로 만들고 SSM에 저장하는 이유는?

<details>
<summary>답 보기</summary>

```hcl
resource "random_password" "db" {
  length  = 20
  special = false  # RDS 비밀번호 특수문자 제한 고려
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project_name}/${var.environment}/DB_PASSWORD"
  type  = "SecureString"  # KMS로 암호화
  value = random_password.db.result

  lifecycle {
    ignore_changes = [value]  # 첫 생성 후 Terraform이 값을 바꾸지 않음
  }
}

resource "aws_db_instance" "main" {
  password = random_password.db.result  # 최초 생성 시만 사용
}
```

**왜 random_password?**
- 사람이 직접 정한 비밀번호는 예측 가능성이 있다
- CI/CD 파이프라인에 비밀번호를 넣을 필요 없이 Terraform이 생성

**왜 SSM SecureString?**
- 앱 서버에서 `aws ssm get-parameter`로 런타임에 가져올 수 있다
- 코드에 비밀번호를 하드코딩하거나 환경 변수에 평문으로 두지 않아도 된다
- KMS 암호화로 저장됨

**`lifecycle { ignore_changes = [value] }` 이유:**
비밀번호가 한번 설정된 후 `random_password.db.result`가 바뀌어도 (예: state 재생성) SSM 값은 변경하지 않는다. RDS 비밀번호와 SSM 값이 달라지는 상황을 방지한다.

</details>

---

### Q. RDS Proxy를 왜 prod에만 쓰나요?

<details>
<summary>답 보기</summary>

```hcl
resource "aws_db_proxy" "main" {
  count = var.enable_rds_proxy ? 1 : 0  # prod: true, dev/staging: false

  connection_pool_config {
    max_connections_percent = 90
    idle_client_timeout     = 1800
  }
}
```

**RDS Proxy란:** 앱 → Proxy → RDS 사이에 커넥션 풀을 관리하는 managed 서비스다.

**필요한 이유:**
- RDS MySQL은 동시 커넥션 수에 제한이 있다
- K8s Pod가 여러 개면 각자 커넥션 풀을 가지므로 Pod 수 × 커넥션 수만큼 RDS에 부하
- Proxy가 커넥션을 pooling해서 RDS 부하를 줄인다

**dev/staging에 없는 이유:**
- EC2 인스턴스 1-2개라 커넥션 수가 적다
- Proxy 자체 비용이 RDS 비용의 일부 (dev는 RDS 자체도 없음)

</details>

---

### Q. `lifecycle { prevent_destroy = true }`를 RDS에만 쓴 이유는?

<details>
<summary>답 보기</summary>

```hcl
resource "aws_db_instance" "main" {
  lifecycle {
    prevent_destroy = true
  }
}
```

`terraform destroy` 또는 실수로 RDS를 삭제하는 코드를 작성했을 때 **plan 단계에서 에러를 발생**시켜 실행을 막는다.

RDS는 한번 삭제되면 최대 7일 자동 백업에서만 복구할 수 있고, 복구 시간도 오래 걸린다. 운영 데이터베이스를 실수로 날리는 건 치명적이다.

EC2는 `prevent_destroy` 없이도 괜찮다 — 컨테이너/CodeDeploy로 재배포하면 된다. NAT도 마찬가지. 하지만 **데이터가 있는 리소스** (RDS, S3, EBS 볼륨)는 신중하게 고려해야 한다.

</details>

---

## 11. Security Group 패턴

---

### Q. SG-to-SG 규칙을 왜 별도 `aws_security_group_rule` 리소스로 뺐나요?

<details>
<summary>답 보기</summary>

```hcl
# 이렇게 하면 안 됨 — 인라인 + 별도 리소스 혼용
resource "aws_security_group" "api" {
  ingress {
    security_groups = [aws_security_group.nginx.id]  # 인라인
  }
}
resource "aws_security_group_rule" "api_from_nginx" {  # 별도 리소스
  security_group_id        = aws_security_group.api.id
  source_security_group_id = aws_security_group.nginx.id
}

# 이 프로젝트의 방식 — cidr_blocks 규칙은 인라인, SG-to-SG는 별도
resource "aws_security_group" "this" {
  for_each = var.services
  dynamic "ingress" {
    for_each = each.value.sg_ingress  # CIDR 기반 규칙만 인라인
    content { ... }
  }
}

resource "aws_security_group_rule" "cross" {
  for_each = { for rule in var.sg_cross_rules : "..." => rule }
  source_security_group_id = aws_security_group.this[each.value.source_key].id
  security_group_id        = aws_security_group.this[each.value.service_key].id
}
```

**이유:** SG-to-SG 규칙을 인라인으로 넣으면 **순환 참조**가 발생할 수 있다. nginx SG에 api SG 참조를 넣고, api SG에 nginx SG 참조를 넣으면 Terraform이 어느 것을 먼저 만들어야 할지 모른다. 별도 `aws_security_group_rule`로 분리하면 두 SG를 먼저 만들고 규칙을 나중에 추가한다.

</details>

---

### Q. `name_prefix`를 `name` 대신 쓰는 이유는?

<details>
<summary>답 보기</summary>

```hcl
resource "aws_security_group" "nat" {
  name_prefix = "${var.project_name}-${var.environment}-nat-"
  # → "doktori-dev-nat-a1b2c3" 처럼 랜덤 suffix 붙음
}
```

`lifecycle { create_before_destroy = true }`와 함께 쓰인다.

SG는 EC2에 연결된 채로는 삭제할 수 없다. SG 설정을 변경하면 Terraform은 새 SG를 만들고 기존 SG를 삭제하는 순서로 진행한다.

`name`을 쓰면 새 SG를 먼저 만들 때 이름 충돌이 발생한다 (같은 이름의 SG가 이미 있음). `name_prefix`를 쓰면 suffix가 달라 충돌이 없다.

`create_before_destroy = true` → 새 리소스를 먼저 만들고 → EC2에 연결 변경 → 기존 리소스 삭제

</details>

---

## 12. Lifecycle 메타 인수

---

### Q. `lifecycle` 블록의 종류와 각각 언제 쓰나요?

<details>
<summary>답 보기</summary>

```hcl
lifecycle {
  # 1. create_before_destroy
  # 기본: destroy → create. 이걸 켜면: create → attach → destroy
  # 용도: SG, 인스턴스 profile 등 "이름이 겹치면 안 되는 것"
  create_before_destroy = true

  # 2. prevent_destroy
  # terraform destroy 또는 삭제 코드 작성 시 plan 단계에서 에러
  # 용도: RDS처럼 실수로 삭제하면 치명적인 리소스
  prevent_destroy = true

  # 3. ignore_changes
  # 명시한 속성이 실제 인프라에서 바뀌어도 Terraform이 감지하지 않음
  # 용도:
  #   - ami, user_data: EC2 교체 없이 AMI 업데이트 무시
  #   - route: 다른 리소스가 추가한 라우팅 무시
  #   - value: SSM 값이 외부에서 변경되어도 덮어쓰지 않음
  ignore_changes = [ami, user_data]

  # 4. replace_triggered_by (Terraform 1.2+)
  # 지정한 리소스/속성이 변경되면 이 리소스를 강제 재생성
  replace_triggered_by = [aws_launch_template.this]
}
```

이 프로젝트에서:
- EC2 인스턴스: `ignore_changes = [ami, user_data]` → Packer로 AMI를 새로 빌드해도 기존 인스턴스는 그대로
- RDS: `prevent_destroy = true` → 실수 방지
- Route Table, SG: `create_before_destroy = true` + `ignore_changes` 조합

</details>

---

## 13. 환경별 설계 차이

---

### Q. dev는 AZ가 1개, prod는 3개인 이유는?

<details>
<summary>답 보기</summary>

```hcl
# dev — 단일 AZ
module "networking" {
  availability_zone = "ap-northeast-2a"
  subnets = {
    public      = { cidr = "10.0.0.0/22",  az_key = "primary" }
    private_app = { cidr = "10.0.16.0/20", az_key = "primary" }
    private_db  = { cidr = "10.0.32.0/24", az_key = "primary" }
  }
}

# prod — 3 AZ (HA)
module "networking" {
  availability_zone           = "ap-northeast-2a"
  secondary_availability_zone = "ap-northeast-2c"
  tertiary_availability_zone  = "ap-northeast-2b"
  subnets = {
    public        = { az_key = "primary"   }
    public_c      = { az_key = "secondary" }
    public_b      = { az_key = "tertiary"  }
    private_app   = { az_key = "primary"   }
    private_app_c = { az_key = "secondary" }
    private_app_b = { az_key = "tertiary"  }
    ...
  }
}
```

**AZ란:** 같은 리전 내의 물리적으로 분리된 데이터센터. AZ 하나가 장애나도 다른 AZ는 살아있다.

dev는 비용 절감과 단순성이 우선이다. 개발 중인 서비스가 잠깐 내려가도 괜찮다. prod는 AZ 장애에도 서비스가 유지되어야 하므로 3 AZ에 리소스를 분산한다.

RDS Subnet Group도 최소 2개 AZ를 요구한다.

</details>

---

### Q. prod S3에만 versioning이 켜진 이유는?

<details>
<summary>답 보기</summary>

```hcl
# dev
s3_buckets = {
  app = {
    bucket_name = "doktori-v2-dev"
    versioning  = false  # 저장 비용 절감
  }
}

# prod
s3_buckets = {
  app = {
    bucket_name = "doktori-v2-prod"
    versioning  = true  # 파일 이력 보존, 실수 복구 가능
  }
}
```

versioning을 켜면:
- 파일을 덮어쓰거나 삭제해도 이전 버전이 남는다
- 실수로 이미지를 삭제해도 복구 가능
- 단점: 모든 버전이 저장되므로 스토리지 비용 증가

dev는 테스트용 파일을 자주 올리고 지우기 때문에 versioning이 오히려 불필요한 비용을 만든다. prod의 사용자 업로드 이미지는 실수 복구 가능성이 있어야 한다.

</details>

---

### Q. dev NAT에 WireGuard VPN이 있는 이유는?

<details>
<summary>답 보기</summary>

```hcl
# dev/base/main.tf
nat_extra_ingress = [
  {
    description = "WireGuard VPN"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
]
nat_extra_tags = {
  Name    = "doktori-dev-nat-vpn"
  Service = "nat-vpn"
}
```

dev 환경의 EC2는 private 서브넷에 있어 외부에서 직접 SSH 접근이 안 된다. WireGuard VPN을 NAT 인스턴스에 올리면:
- 개발자가 VPN으로 연결 → dev private 서브넷 IP로 직접 접근 가능
- SSH 포트를 인터넷에 노출하지 않아도 됨
- SSM Session Manager와 보완적으로 사용

prod에는 VPN이 없다 — SSM Session Manager만으로 접근하고, 인터넷에서 아무것도 직접 열지 않는다.

</details>

---

## 14. moved 블록

---

### Q. `moved` 블록은 뭐고 왜 필요한가요?

<details>
<summary>답 보기</summary>

```hcl
moved {
  from = aws_instance.nat
  to   = aws_instance.nat["primary"]
}
```

리소스의 **Terraform 내부 주소를 변경**할 때 사용한다. state 파일에서 기존 주소의 리소스를 새 주소로 **이동**시킨다.

**사용 배경:**
처음에는 NAT 인스턴스가 1개라서 `resource "aws_instance" "nat"`로 단일 리소스였다. 이후 prod HA를 위해 `for_each`로 바꾸면서 주소가 `aws_instance.nat["primary"]`로 바뀌었다.

`moved` 블록이 없으면:
- Terraform이 `aws_instance.nat`를 삭제하고 `aws_instance.nat["primary"]`를 새로 생성
- NAT 인스턴스가 교체되면서 다운타임 발생

`moved` 블록이 있으면:
- state에서 주소만 변경, 실제 AWS 리소스는 그대로
- `terraform plan`에서 "moved" 메시지만 출력, 리소스 교체 없음

리팩터링 시 리소스를 삭제/재생성 없이 이름을 바꿀 수 있다.

</details>

<details>
<summary>관련 개념 — terraform state mv (moved 블록 이전 방식)</summary>

`moved` 블록(Terraform 1.1+) 이전에는 CLI 명령으로 직접 처리했다:

```bash
terraform state mv aws_instance.nat 'aws_instance.nat["primary"]'
```

`moved` 블록이 코드로 들어오면서:
- 팀원 모두가 동일한 state 이동을 자동으로 적용 받음
- 리뷰 가능 (PR에 포함됨)
- 적용 후 `moved` 블록은 지워도 되지만 히스토리 목적으로 유지하기도 함

</details>

---

## 빠른 참고 — 자주 쓰는 Terraform CLI

```bash
# 초기화 (provider 다운로드, backend 연결)
terraform init

# 변경 계획 미리보기
terraform plan

# 적용
terraform apply

# 특정 리소스만 적용
terraform apply -target=module.networking.aws_vpc.main

# 리소스 상태 조회
terraform state list
terraform state show aws_instance.this["app"]

# 이미 존재하는 리소스를 state에 등록
terraform import aws_instance.this["app"] i-0abc123

# state에서 리소스 주소 이동
terraform state mv 'aws_instance.nat' 'aws_instance.nat["primary"]'

# 출력값 확인
terraform output
terraform output -json | jq .

# 특정 리소스 강제 재생성
terraform apply -replace=aws_instance.this["app"]

# 변수 파일 지정
terraform plan -var-file=dev.tfvars
```

---

*이 문서는 `5-team-service-cloud/terraform/` 코드를 기반으로 작성되었다.*
