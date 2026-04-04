# Roadmap: Terraform 인프라 리팩토링 및 dev 환경 재구축

## 날짜: 2026-03-31
## 상태: Draft
## 목적: 새 AWS 계정에서 Terraform 구성 원칙을 정립하고, 의존성이 깔끔하게 분리된 dev 환경을 재구축한다.

---

### 배경 (Context)

> 기존 Terraform 코드를 점검한 결과, 레이어 간 의존성 위반(하위 레이어가 상위 리소스 수정), 하드코딩된 CIDR,
> DynamoDB 기반 state locking 등 구조적 문제가 발견되었다.
> 새 AWS 계정에서 인프라를 다시 올리기 전에 이 문제들을 정리하고,
> "순서대로 만들었다면 역순으로 부숴도 문제없는" 구조를 만든다.
>
> 이 작업의 선행으로 `terraform/PRINCIPLES.md`에 팀 구성 원칙을 문서화했다.

---

### 원칙 (Principles)

> `terraform/PRINCIPLES.md`에 정의된 원칙을 따른다. 핵심만 요약:

- **레이어 분리 기준**: 변경 빈도 x 영향 범위(blast radius)로 판단
- **의존성 단방향**: 하위 -> 상위 참조만 허용, `terraform_remote_state` output으로만 읽기
- **상위 리소스 수정 금지**: 하위 레이어에서 상위/동위 레이어의 리소스를 생성/수정/삭제하지 않음 (예외 없음)
- **네이밍**: `{project}-{env}-{resource}`
- **Destroy 순서**: 생성의 정확한 역순 보장

---

### 전체 구조 (Overview)

```
Phase 0 (코드 정리) ──► Phase 1 (Bootstrap) ──► Phase 2 (Global + Shared) ──► Phase 3 (dev/base) ──► Phase 4 (dev/app)
                                                        │
                                                        ├── ecr
                                                        ├── dns-zone
                                                        └── monitoring
                                                              │
                                                              └──► Phase 3로 합류 (dev/base가 peering 참조)
```

| Phase | 이름 | 선행 조건 | 핵심 산출물 |
|-------|------|----------|-----------|
| 0 | 코드 리팩토링 | 없음 | 원칙에 부합하는 Terraform 코드 |
| 1 | Bootstrap | Phase 0 완료 | S3 state bucket |
| 2 | Global + Shared | Phase 1 완료 | IAM, OIDC, ECR, DNS, Monitoring |
| 3 | dev/base | Phase 2 완료 (monitoring 필수) | VPC, NAT, S3, VPC Peering |
| 4 | dev/app | Phase 3 완료 | EC2 x4, Lambda, EventBridge |

---

### Phase 0: 코드 리팩토링

**목적**: PRINCIPLES.md 원칙에 위반되는 코드를 수정하여 안전한 apply/destroy를 보장한다
**선행 조건**: 없음 (코드 수정만, AWS 리소스 생성 없음)
**완료 기준**: 모든 레이어가 단방향 의존성 원칙을 준수하고, `terraform validate` 통과

#### 작업 목록

- [ ] **VPC Peering mgmt route를 monitoring 레이어로 이동** — dev/base, prod/base에서 monitoring VPC route table에 route를 생성하는 코드를 monitoring/ 쪽으로 옮긴다
  - 대상 파일/리소스:
    - `terraform/environments/dev/base/main.tf` — `aws_route.mgmt_to_dev` (L168-172), `data.aws_route_table.mgmt_main` (L159-166) 제거
    - `terraform/environments/prod/base/main.tf` — `aws_route.mgmt_to_prod` (L139-142) 제거
    - `terraform/monitoring/main.tf` — 각 환경으로의 route를 여기서 관리하도록 추가
  - 이유: 하위 레이어(dev/base)가 상위/동위 레이어(monitoring)의 리소스를 수정하는 것은 원칙 위반. destroy 순서 의존성을 제거하기 위함
  - 주의: monitoring에서 각 환경의 VPC ID와 peering connection ID를 참조해야 하므로, dev/base와 prod/base에서 peering connection을 output으로 노출해야 함. 의존성 방향이 `monitoring → dev/base`가 되지 않도록 설계 필요

- [ ] **Route53 zone association을 monitoring 레이어로 이동** — dev/base의 `aws_route53_zone_association.mgmt_phz_dev`도 같은 원칙으로 이동
  - 대상 파일/리소스: `terraform/environments/dev/base/main.tf` — `aws_route53_zone_association.mgmt_phz_dev` (L175-178)
  - 이유: monitoring의 PHZ를 dev VPC에 연결하는 것은 monitoring 쪽 관심사

- [ ] **하드코딩된 외부 CIDR을 변수화** — app SG에 직접 박혀있는 prod VPC CIDR, RDS replication IP를 변수로 추출
  - 대상 파일/리소스: `terraform/environments/dev/app/main.tf` — `10.1.0.0/16` (L111), `15.164.45.30/32` (L112), `10.100.0.0/24` (Qdrant SG L144)
  - 이유: 환경 간 하드코딩 참조는 재구축 시 의미 없는 rule이 되며, 변경 추적이 어려움

- [ ] **DynamoDB 관련 코드 제거 확인** — 이미 이번 세션에서 수정 완료. 누락 없는지 최종 확인
  - 대상 파일/리소스: `backend.hcl`, `backend/main.tf`, `backend/outputs.tf`, `global/main.tf`
  - 이유: Terraform 1.10+ S3 native lockfile로 전환 완료, DynamoDB 잔재 제거

- [ ] **CI Terraform 버전 통일 확인** — 이미 1.14.8로 수정 완료. 누락된 워크플로우가 없는지 확인
  - 대상 파일/리소스: `.github/workflows/terraform.yml`, `.github/workflows/terraform-staging.yml`
  - 이유: 로컬(1.14.8)과 CI 버전이 일치해야 `use_lockfile` 등 기능이 동일하게 동작

#### 검증 방법

- [ ] 모든 레이어에서 `terraform validate` 통과
- [ ] `grep -r "mgmt_to_dev\|mgmt_to_prod" terraform/environments/` — 결과 없음 확인
- [ ] `grep -r "dynamodb" terraform/` — 결과 없음 확인 (README 설명 제외)

#### 위험 요소

| 위험 | 영향 | 대응 방안 |
|------|------|----------|
| monitoring에서 env별 peering route를 관리하면 의존성 방향이 꼬일 수 있음 | monitoring이 dev/base state를 참조하게 되면 순환 의존성 | peering connection은 env/base에서 생성하되, monitoring은 AWS API(data source)로 peering connection을 조회하여 route만 추가 |
| 기존 state에 있는 리소스를 다른 레이어로 옮기면 state migration 필요 | `terraform state mv` 실수 시 리소스 재생성 | 새 계정에서 처음부터 올리므로 state migration 불필요 |

---

### Phase 1: Bootstrap

**목적**: 다른 모든 레이어가 state를 저장할 S3 bucket을 생성한다
**선행 조건**: Phase 0 완료, 새 AWS 계정 접근 가능
**완료 기준**: `aws s3 ls s3://doktori-v2-terraform-state` 성공

#### 작업 목록

- [ ] **S3 state bucket 생성** — `terraform apply` (로컬 state로 초기 실행 후 migrate)
  - 대상 파일/리소스: `terraform/backend/main.tf`
  - 이유: 모든 레이어의 S3 backend 전제 조건
  - 주의: 이 레이어만 유일하게 로컬 state로 시작 후 S3로 migrate 해야 함

#### 검증 방법

- [ ] `aws s3 ls s3://doktori-v2-terraform-state` — 버킷 존재 확인
- [ ] `terraform init -backend-config=backend.hcl` — 다른 레이어에서 init 성공

#### 위험 요소

| 위험 | 영향 | 대응 방안 |
|------|------|----------|
| 버킷 이름 중복 (다른 계정에서 이미 사용) | init 실패 | 버킷 이름에 계정 ID prefix 추가 검토 |

---

### Phase 2: Global + Shared

**목적**: 환경에 종속되지 않는 계정 수준 설정과 공유 인프라를 생성한다
**선행 조건**: Phase 1 완료 (S3 state bucket 존재)
**완료 기준**: OIDC, IAM, ECR repo, DNS zone, Monitoring 인스턴스 모두 정상 동작

#### 작업 목록

- [ ] **global apply** — OIDC Provider, Admin IAM, Budget, GitHub Actions Role
  - 대상 파일/리소스: `terraform/global/main.tf`
  - 이유: CI/CD 파이프라인과 팀 접근 제어의 전제 조건

- [ ] **ecr apply** — ECR 리포지토리 생성
  - 대상 파일/리소스: `terraform/ecr/main.tf`
  - 이유: app 레이어에서 이미지 pull에 필요

- [ ] **dns-zone apply** — Route53 Hosted Zone + 레코드
  - 대상 파일/리소스: `terraform/dns-zone/main.tf`
  - 이유: 도메인 연결
  - 주의: 새 계정이면 도메인 레지스트라에서 NS 레코드 변경 필요

- [ ] **monitoring apply** — Monitoring 인스턴스 + Private Hosted Zone + 환경별 peering route
  - 대상 파일/리소스: `terraform/monitoring/main.tf`
  - 이유: dev/base가 monitoring VPC로 peering하므로 반드시 먼저 존재해야 함
  - 주의: Phase 0에서 옮긴 peering route 코드가 포함됨. 아직 env VPC가 없으므로 peering route는 conditional로 처리 필요

#### 검증 방법

- [ ] `aws sts assume-role-with-web-identity` — GitHub OIDC 인증 테스트
- [ ] `aws ecr describe-repositories` — ECR repo 목록 확인
- [ ] `aws route53 list-hosted-zones` — zone 존재 확인
- [ ] `aws ec2 describe-instances --filters "Name=tag:Service,Values=monitoring"` — 모니터링 인스턴스 확인

#### 위험 요소

| 위험 | 영향 | 대응 방안 |
|------|------|----------|
| DNS NS 전파 지연 | 도메인 접근 불가 (최대 48시간) | 다른 Phase와 병렬 진행, DNS는 비동기로 대기 |
| monitoring의 peering route가 아직 대상 VPC 없이 apply됨 | plan 에러 또는 불필요한 리소스 | `count` 또는 `for_each`로 conditional 처리, env VPC 정보를 variable로 받아서 비어있으면 skip |

---

### Phase 3: dev/base

**목적**: dev 환경의 네트워크 기반을 구축한다
**선행 조건**: Phase 2 완료 (monitoring VPC 존재, monitoring state에서 mgmt_vpc_id 참조 가능)
**완료 기준**: VPC, NAT, S3 bucket, VPC Peering, SSM Parameters 모두 생성 완료

#### 작업 목록

- [ ] **dev/base apply** — VPC(10.0.0.0/16), NAT Instance, S3, SSM Parameters, VPC Peering
  - 대상 파일/리소스: `terraform/environments/dev/base/main.tf`
  - 이유: dev/app의 모든 리소스가 이 VPC 안에 배치됨
  - 주의: VPC Peering 생성 후 monitoring 쪽에서 mgmt->dev route를 추가해야 함 (Phase 0에서 리팩토링한 부분)

- [ ] **monitoring re-apply** — dev VPC로의 peering route 활성화
  - 대상 파일/리소스: `terraform/monitoring/main.tf`
  - 이유: dev/base가 peering connection을 만들었으므로, monitoring에서 역방향 route를 추가해야 양방향 통신 가능
  - 주의: monitoring apply가 기존 리소스에 영향 안 주는지 plan으로 먼저 확인

#### 검증 방법

- [ ] `aws ec2 describe-vpcs --filters "Name=tag:Name,Values=doktori-dev-vpc"` — VPC 확인
- [ ] `aws ec2 describe-vpc-peering-connections` — peering 상태 `active` 확인
- [ ] dev VPC 내부에서 monitoring 인스턴스로 ping 가능 확인

#### 위험 요소

| 위험 | 영향 | 대응 방안 |
|------|------|----------|
| monitoring re-apply 시 기존 리소스에 예상치 못한 변경 | 모니터링 서비스 중단 | `terraform plan` 먼저 실행, peering route 추가만 있는지 diff 확인 |

---

### Phase 4: dev/app

**목적**: dev 환경의 애플리케이션 인스턴스와 부속 리소스를 배포한다
**선행 조건**: Phase 3 완료 (VPC, subnet, NAT, S3 존재)
**완료 기준**: EC2 4대(app, ai, ai_qdrant, ai_batch), Lambda, EventBridge 모두 정상 생성, 내부 DNS 등록 완료

#### 작업 목록

- [ ] **dev/app apply** — EC2 x4, Security Groups, Lambda(batch start), EventBridge Scheduler, Route53 내부 DNS
  - 대상 파일/리소스: `terraform/environments/dev/app/main.tf`
  - 이유: 실제 서비스가 동작하는 계층
  - 주의: batch 인스턴스는 생성 후 자동 stopped 상태로 전환됨 (`aws_ec2_instance_state`)

- [ ] **Lambda 배포 파일 확인** — `lambda/start_tagged_instances.py` 존재 여부
  - 대상 파일/리소스: `terraform/environments/dev/app/lambda/start_tagged_instances.py`
  - 이유: `data.archive_file`이 이 파일을 zip으로 패키징하므로 없으면 apply 실패

- [ ] **user_data 템플릿 확인** — batch, qdrant용 템플릿 존재 여부
  - 대상 파일/리소스: `terraform/environments/dev/app/templates/dev_ai_batch_user_data.sh.tftpl`, `dev_qdrant_user_data.sh.tftpl`
  - 이유: `templatefile()` 참조 대상이 없으면 apply 실패

#### 검증 방법

- [ ] `aws ec2 describe-instances --filters "Name=tag:Environment,Values=dev"` — 4대 인스턴스 확인
- [ ] `aws lambda get-function --function-name doktori-dev-start-weekly-batch` — Lambda 존재 확인
- [ ] `aws route53 list-resource-record-sets --hosted-zone-id <zone_id>` — 내부 DNS 레코드 확인
- [ ] SSM으로 app 인스턴스 접속 테스트

#### 위험 요소

| 위험 | 영향 | 대응 방안 |
|------|------|----------|
| 하드코딩된 CIDR이 새 계정 환경과 안 맞음 | SG rule이 의미 없는 대역을 허용 | Phase 0에서 변수화 완료 후 새 값으로 설정 |
| ECR에 이미지가 아직 없음 | batch user_data에서 docker pull 실패 | 이미지 push를 app apply 전에 수행하거나, user_data에 pull 실패 시 graceful exit 처리 |

---

### 의존성 맵 (Dependency Map)

```
Phase 0 (코드 정리)
    │
    ▼
Phase 1 (backend)
    │
    ▼
Phase 2 (global + shared) ─────────────────────────┐
    │                                                │
    ├── global    (IAM, OIDC, Budget)                │
    ├── ecr       (image repositories)               │
    ├── dns-zone  (Route53)                          │
    └── monitoring (EC2, PHZ) ◄──────────────────────┤
         │                                            │
         ▼                                            │
Phase 3 (dev/base) ──► monitoring re-apply            │
    │                  (역방향 route 활성화)            │
    ▼                                                 │
Phase 4 (dev/app)                                     │
                                                      │
    향후: staging, prod도 동일 패턴 ◄─────────────────┘
```

---

### 결정 사항 (Decisions Made)

> 대화에서 이미 합의된 결정. 실행 시 다시 논의하지 않는다.

| # | 결정 | 이유 | 대안 | 대안 탈락 이유 |
|---|------|------|------|--------------|
| 1 | DynamoDB state lock 제거, S3 `use_lockfile = true` 전환 | Terraform 1.10+에서 네이티브 S3 locking 지원, DynamoDB 불필요 | DynamoDB 유지 | 불필요한 리소스 관리 포인트 |
| 2 | CI Terraform 버전 1.14.3 -> 1.14.8 통일 | 로컬과 CI 버전 불일치 방지, `use_lockfile` 지원 보장 | 버전 차이 허용 | 기능 차이로 인한 예측 불가능한 동작 |
| 3 | VPC Peering mgmt route를 monitoring 레이어로 이동 | 하위 레이어가 상위 리소스 수정하는 것은 원칙 위반 | 각 env/base에서 관리 (현재) | 원칙에 예외를 두지 않기로 합의 |
| 4 | 네트워크/연결 계층 분리 안 함 | dev/staging/prod 3개 환경, 소규모 팀에서는 과분리 | base를 network + connectivity로 분리 | 변경 빈도와 영향 범위가 동일하여 분리 실익 없음 |
| 5 | Shared 레이어(ecr, dns-zone, monitoring) state 개별 분리 유지 | blast radius 격리, 서로 의존성 없음 | shared/ 디렉토리로 묶기 | 디렉토리 정리뿐이고 state key/CI 수정 비용 대비 실익 없음 |
| 6 | dev에 data 레이어 없음 유지 | DB가 Docker Compose로 EC2 내부에서 운영 | data 레이어 분리 | Terraform이 관리할 대상이 아님 |
| 7 | CDN Deploy Policy를 prod/cdn 레이어로 이동 | 특정 리소스 ARN(S3, CloudFront)에 종속된 policy는 해당 리소스 레이어에서 attachment. Role 엔티티만 global에 유지 | global에 유지 | 리소스 생성 전 ARN 참조 불가, 업계 표준과 불일치 |
| 8 | 구성 원칙을 `terraform/PRINCIPLES.md`로 문서화 | 팀 합의 기반 운영, 레이어 분리/의존성 규칙의 근거 | README에 포함 | 원칙과 운영 가이드는 성격이 다름, 별도 문서가 적합 |

---

### 미결 사항 (Open Questions)

> 아직 결정되지 않은 것. 해당 Phase 진입 전에 결정 필요.

- [x] **`10.100.0.0/24` CIDR의 정체** — monitoring mgmt VPC CIDR. `local.mgmt_vpc_cidr`으로 대체 완료 (하드코딩 제거)
- [ ] **monitoring에서 env별 peering route를 어떻게 conditional 처리할지** — 환경이 아직 없을 때 monitoring apply가 에러 없이 동작해야 함. Phase 0에서 설계 필요
- [ ] **시크릿 관리 도구 전환 (SSM -> Infisical 등)** — CSP 종속 제거 목적. 인프라 올린 후 마이그레이션하기로 했으나, 구체적 시점과 도구 미정
- [ ] **staging의 monitoring peering 필요 여부** — 현재 staging만 peering이 없음. 상시 운영이 아니라서 빠진 것인지 의도적 결정인지 확인 필요
- [ ] **새 계정에서 S3 bucket 이름 충돌 여부** — `doktori-v2-terraform-state` 등 글로벌 유니크 이름. Phase 1 진입 전에 확인

---

### 변경 이력 (Changelog)

| 날짜 | 변경 내용 |
|------|----------|
| 2026-03-31 | 초안 작성 |
| 2026-04-02 | Phase 1(backend), Phase 2 global/ecr apply 완료. global 리팩토링: KMS 하드코딩 제거, CDN policy → prod/cdn 이동, Admin 그룹 → cloud_team 통합, grafana-billing-reader user 제거, feature/s3-CDN OIDC subject 제거. ECR: dev/prod 레포 통합, 태그 기반 lifecycle policy 도입(dev-*/prod-* prefix). 결정사항 #7 업데이트. |
| 2026-04-02 | monitoring 레이어 base/data/app 전면 분리 완료. mgmt VPC(172.16.0.0/16) 신설 + NAT 인스턴스(WireGuard 겸용). terraform_remote_state 방식으로 레이어 간 참조 전환 (AWS data source 방식 폐기). PRINCIPLES.md §1~§7 업데이트. Loki compactor delete_request_store 버그 수정(filesystem→s3), rate limit 설정 추가. 구 계정 Loki S3 데이터 삭제 결정(152k 객체, compactor 상태 오염). dns_zone apply 완료. |
| 2026-04-03 | monitoring/data apply 완료(S3 import, lifecycle 수정). monitoring/app apply 완료(EIP 제거, SG ASCII 수정). monitoring 서버 docker compose 배포 완료(cadvisor registry 이전 ghcr→gcr, blackbox-exporter latest→v0.28.0 고정, docker login 임시). CLAUDE.md remote_state 정책 충돌 수정. 로드맵 ansible-monitoring-deploy.md 신규 작성. 다음: dev/base → monitoring re-apply → dev/data → dev/app. |
| 2026-04-03 | SSM 파라미터 전체 정리 완료: CI/CD 전용 제거, Terraform-write 값 직접 관리(AWS_REGION, ECR_REGISTRY, S3 params 등), 주입 스크립트(ssm_inject_dev.sh/prod.sh) 신규 작성. dev/base 코드 점검 완료: NAT AMI 24.04→22.04 통일, random_password 위치 정리, QDRANT_URL ignore_changes 제거, RUNPOD_POLL_TIMEOUT_SECONDS common_parameters 이동, SSM 섹션 중복 헤더 제거. dev/data 코드 점검 완료: S3 버킷명 doktori-v2-dev→doktori-dev, backup/ 폴더 및 AWS_S3_DB_BACKUP 제거. cross-account S3 마이그레이션 완료(297MB, doktori-v2-dev→doktori-dev). dev/app 코드 점검 완료: ssm_parameter_path 이름 정리, qdrant_external_cidr→local.mgmt_vpc_cidr, QDRANT__SERVICE__HOST DNS명→0.0.0.0(Docker 바인드 버그 수정), batch runner INSTANCE_ID 메타데이터 API 조회로 수정, lambda zip git untrack. **dev/base, dev/data, dev/app apply 완료. Phase 3~4 완료.** |
