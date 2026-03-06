# Terraform 모듈 리팩토링 Roadmap

> prod/nonprod 코드 복사 구조를 modules/ + environments/ 모듈 구조로 전환, 환경당 base/app/data 3-layer state + CI/CD 파이프라인 구축
>
> 트래킹 시작: 2026-02-21
> 전면 리팩토링 계획 수립: 2026-03-06

---

## 진행 현황

| Phase | 제목 | 상태 | 완료일 | 비고 |
|:-----:|------|:----:|:-----:|------|
| 0 | [설계 확정 & 잔존물 정리](#phase-0-설계-확정--잔존물-정리) | ✅ Done | 2026-03-06 | state 전략/모듈 구조 확정 |
| 1 | [모듈 작성 — networking](#phase-1-모듈-작성--networking) | ✅ Done | 2026-03-06 | VPC, subnet(for_each), NAT, VPC endpoint(for_each) |
| 2 | [모듈 작성 — storage](#phase-2-모듈-작성--storage) | ✅ Done | 2026-03-06 | S3(for_each), ECR(for_each), KMS |
| 3 | [모듈 작성 — compute](#phase-3-모듈-작성--compute) | ✅ Done | 2026-03-06 | services map + for_each + SG cross-rule |
| 4 | [모듈 작성 — database](#phase-4-모듈-작성--database) | ✅ Done | 2026-03-06 | RDS + prevent_destroy + SSM secret |
| 5 | [환경 구성 — dev](#phase-5-환경-구성--dev) | ✅ Done | 2026-03-06 | dev/base + dev/app 작성 |
| 6 | [환경 구성 — prod](#phase-6-환경-구성--prod) | ✅ Done | 2026-03-06 | prod/base + prod/app + prod/data 작성 |
| 7 | [State 마이그레이션 — dev](#phase-7-state-마이그레이션--dev) | ✅ Done | 2026-03-06 | dev-base + dev-app 완료, No changes 확인 |
| 8 | [State 마이그레이션 — prod](#phase-8-state-마이그레이션--prod) | ✅ Done | 2026-03-06 | prod-base + prod-app + prod-data 완료 |
| 9 | [CI/CD 파이프라인](#phase-9-cicd-파이프라인) | ✅ Done | 2026-03-06 | .github/workflows/terraform.yml 작성 완료 |
| 10 | [정리 & 문서화](#phase-10-정리--문서화) | 🔄 In Progress | - | Phase 2: storage import + 구 폴더 삭제 |

---

## 설계 배경 (Architecture Decision Records)

### State 분리 전략: 환경당 3개 (base/app/data)

| 분리 기준 | 근거 | 출처 |
|-----------|------|------|
| 변경 빈도 | networking 거의 안 바뀜, compute 자주 바뀜 → 분리 | [HashiCorp Workspace Best Practices](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/best-practices) |
| Stateful/Stateless | DB recreate = 데이터 손실 → DB 별도 state | HashiCorp 공식 |
| Lock 충돌 | base apply 중 app 배포 블락 방지 | 업계 사례 |
| 과분리 방지 | remote_state 2개로 제한 (app→base, data→base) | [Xebia: Anti-patterns of Layers](https://xebia.com/blog/anti-patterns-of-using-layers-with-terraform/) |

### 모듈 구조 선택: for_each + dynamic blocks

- prod 6 인스턴스, dev 1 인스턴스를 **같은 모듈, 다른 값**으로 처리
- SG 간 참조(front←nginx)는 `aws_security_group_rule`로 분리하여 for_each 호환

### 구조 비교

```
Before (현재)                          After (목표)
─────────────────────────              ─────────────────────────
terraform/                             terraform/
├── prod/                              ├── modules/           ← 코드 1벌
│   ├── networking/ ← 복사본           │   ├── networking/
│   ├── compute/    ← 복사본           │   ├── compute/
│   ├── storage/    ← 복사본           │   ├── storage/
│   ├── database/                      │   └── database/
│   └── dns/                           ├── environments/      ← 값만 다름
├── nonprod/                           │   ├── prod/
│   ├── networking/ ← 복사본           │   │   ├── base/      (networking + storage)
│   ├── compute/    ← 복사본           │   │   ├── app/       (compute)
│   ├── storage/    ← 복사본           │   │   └── data/      (RDS)
│   └── dns/                           │   ├── staging/       (on-demand, prod와 동일)
├── global/                            │   └── dev/
├── monitoring/                        │       ├── base/
├── iam/            ← global과 중복    │       └── app/
├── parameter-store/← storage와 중복   ├── global/            ← 유지
├── dns-zone/                          ├── monitoring/        ← 유지
└── _shared/                           └── dns-zone/          ← 유지

State: 환경당 5개 = 13+개              State: 환경당 3개 = 10개
코드: prod/nonprod 복사                코드: modules/ 1벌
```

---

## Phase 0: 설계 확정 & 잔존물 정리

**목표:** 구조 설계 확정, 사용하지 않는 디렉토리/중복 리소스 정리

### Checklist
- [x] State 분리 전략 결정 (환경당 base/app/data 3개)
- [x] 모듈 구조 설계 (networking, compute, storage, database)
- [x] 환경 구성 설계 (prod, staging, dev)
- [ ] `terraform/s3/` 디렉토리 삭제 (state 없는 잔존물) — Phase 2
- [ ] `terraform/iam/` → `terraform/global/` 통합 — Phase 2
- [ ] `terraform/parameter-store/` KMS → storage 모듈로 통합 — Phase 2

### 산출물 (예상)
- (삭제/통합만 수행)

---

## Phase 1: 모듈 작성 — networking

**목표:** VPC, subnet, NAT, route table, VPC endpoint를 재사용 가능한 모듈로 추출

### Checklist
- [x] `modules/networking/main.tf` 작성
- [x] `modules/networking/variables.tf`
- [x] `modules/networking/outputs.tf`
- [x] `terraform validate` 통과

### 산출물 (예상)
- `terraform/modules/networking/main.tf`
- `terraform/modules/networking/variables.tf`
- `terraform/modules/networking/outputs.tf`

### 참고 (현재 코드)
- `terraform/prod/networking/main.tf` — prod 기준 리소스
- `terraform/nonprod/networking/main.tf` — nonprod 기준 리소스

---

## Phase 2: 모듈 작성 — storage

**목표:** S3, ECR, KMS를 for_each로 동적 생성하는 모듈

### Checklist
- [x] `modules/storage/main.tf` 작성
- [x] `modules/storage/variables.tf`
- [x] `modules/storage/outputs.tf`
- [x] `terraform validate` 통과
- [ ] Phase 2: 기존 S3/ECR/KMS terraform import 필요

### 산출물 (예상)
- `terraform/modules/storage/main.tf`
- `terraform/modules/storage/variables.tf`
- `terraform/modules/storage/outputs.tf`

### 참고 (현재 코드)
- `terraform/prod/storage/main.tf`
- `terraform/nonprod/storage/main.tf` (outputs.tf에 버그 있음 — aws_s3_bucket.images 참조하지만 실제는 aws_s3_bucket.main)

---

## Phase 3: 모듈 작성 — compute

**목표:** EC2 + SG + IAM을 services map 기반 for_each로 생성. 포트폴리오 핵심.

### Checklist
- [x] `modules/compute/main.tf` 작성 (for_each + dynamic ingress + SG cross-rules + lifecycle ignore description)
- [x] `modules/compute/variables.tf`
- [x] `modules/compute/outputs.tf`
- [x] `terraform validate` 통과

### 산출물 (예상)
- `terraform/modules/compute/main.tf`
- `terraform/modules/compute/variables.tf`
- `terraform/modules/compute/outputs.tf`
- `terraform/modules/compute/scripts/nginx_user_data.sh`

### 핵심 설계 — prod 호출 예시
```hcl
module "compute" {
  source = "../../../modules/compute"
  services = {
    nginx          = { instance_type = "t4g.micro",  architecture = "arm64", subnet_key = "public",      associate_eip = true }
    front          = { instance_type = "t4g.small",  architecture = "arm64", subnet_key = "private_app" }
    api            = { instance_type = "t4g.small",  architecture = "arm64", subnet_key = "private_app" }
    chat           = { instance_type = "t4g.medium", architecture = "arm64", subnet_key = "private_app" }
    ai             = { instance_type = "t4g.medium", architecture = "arm64", subnet_key = "private_app" }
    rds_monitoring = { instance_type = "t3.micro",   architecture = "x86",   subnet_key = "public" }
  }
  sg_cross_rules = [
    { service_key = "front", source_key = "nginx", from_port = 3000, to_port = 3001, protocol = "tcp" },
    { service_key = "api",   source_key = "nginx", from_port = 8080, to_port = 8082, protocol = "tcp" },
    { service_key = "chat",  source_key = "nginx", from_port = 8081, to_port = 8083, protocol = "tcp" },
    { service_key = "ai",    source_key = "nginx", from_port = 8000, to_port = 8000, protocol = "tcp" },
  ]
}
```

### 핵심 설계 — dev 호출 예시
```hcl
module "compute" {
  source = "../../../modules/compute"
  services = {
    dev_app = { instance_type = "t4g.medium", architecture = "arm64", subnet_key = "public", associate_eip = true, volume_size = 60 }
  }
  sg_cross_rules = []  # SG 간 참조 없음
}
```

### 참고 (현재 코드)
- `terraform/prod/compute/main.tf` — 6 인스턴스 + 6 SG + IAM
- `terraform/nonprod/compute/main.tf` — 1 인스턴스 + 1 SG + IAM (95% 동일)

---

## Phase 4: 모듈 작성 — database

**목표:** RDS를 별도 모듈로 추출, 3중 보호 장치 적용

### Checklist
- [x] `modules/database/main.tf` 작성 (prevent_destroy + deletion_protection + db_extra_parameters)
- [x] `modules/database/variables.tf`
- [x] `modules/database/outputs.tf`
- [x] `terraform validate` 통과

### 산출물 (예상)
- `terraform/modules/database/main.tf`
- `terraform/modules/database/variables.tf`
- `terraform/modules/database/outputs.tf`

### 참고 (현재 코드)
- `terraform/prod/database/main.tf`

---

## Phase 5: 환경 구성 — dev

**목표:** dev/base + dev/app 작성, 모듈 호출 + tfvars

### Checklist
- [x] `environments/dev/base/` — networking module (storage는 Phase 2)
- [x] `environments/dev/app/` — compute module (dev_app + dev_ai + cross-rule)
- [x] `terraform init` + `terraform validate` 통과

### 산출물 (예상)
- `terraform/environments/dev/base/{main,variables,outputs,providers}.tf`
- `terraform/environments/dev/app/{main,variables,outputs,providers}.tf`

---

## Phase 6: 환경 구성 — prod

**목표:** prod/base + prod/app + prod/data 작성

### Checklist
- [x] `environments/prod/base/` — networking module (storage는 Phase 2)
- [x] `environments/prod/app/` — compute module (6 services + 4 cross-rules)
- [x] `environments/prod/data/` — database module (GTID params 포함)
- [x] `terraform init` + `terraform validate` 통과

### 산출물 (예상)
- `terraform/environments/prod/base/{main,variables,outputs,providers}.tf`
- `terraform/environments/prod/app/{main,variables,outputs,providers}.tf`
- `terraform/environments/prod/data/{main,variables,outputs,providers}.tf`

---

## Phase 7: State 마이그레이션 — dev

**목표:** 기존 nonprod state → 새 dev/base + dev/app state로 이동 (인프라 중단 없음)

### Checklist
- [x] 전체 state 백업 (12개 파일)
- [x] nonprod/networking → nonprod/base (15 리소스 state mv)
- [x] nonprod/compute → nonprod/app (12 리소스 state mv, dev_ai 포함)
- [x] dev/base: `terraform plan` → **"No changes"** ✅
- [x] dev/app: `terraform plan` → **"No changes"** ✅ (SG description lifecycle fix, cross-rule import)

### 주의사항
- for_each 전환 시 resource address가 바뀌므로 매핑을 정확히 해야 함
- 실패 시 백업에서 복원 가능

---

## Phase 8: State 마이그레이션 — prod

**목표:** 기존 prod 5개 state → 새 prod/base + prod/app + prod/data로 이동

### Checklist
- [x] prod/networking → prod/base (20 리소스 state mv, RT 통합)
- [x] prod/compute → prod/app (19 리소스 state mv + 3 cross-rule import + 1 new)
- [x] prod/database → prod/data (6 리소스 state mv, GTID params 보존, publicly_accessible 보안 수정)
- [x] prod/base: `terraform plan` → **"No changes"** ✅
- [x] prod/app: `terraform plan` → **"No changes"** ✅
- [x] prod/data: `terraform plan` → **"No changes"** ✅

### 주의사항
- SG cross-rule 전환 시 순간적 규칙 재생성 → 유지보수 시간대 권장
- 반드시 state 백업 후 진행

---

## Phase 9: CI/CD 파이프라인

**목표:** PR → terraform plan 자동 → 리뷰 → merge → apply. 콘솔 직접 수정 방지.

### Checklist
- [x] `.github/workflows/terraform.yml` 작성
- [x] detect-changes + plan (matrix) + apply (ordered: base → app → data)
- [ ] PR 올려서 plan 코멘트 자동 생성 확인 — Phase 2

### 산출물 (예상)
- `.github/workflows/terraform.yml`

---

## Phase 10: 정리 & 문서화

**목표:** 구 폴더 삭제, 설계 의사결정 문서화

### Checklist
- [x] Wiki 마이그레이션 문서 작성 (`Terraform-migration.md`)
- [ ] Storage import (S3, ECR, KMS) → base layer에 추가
- [ ] 구 state key S3에서 삭제
- [ ] 구 디렉토리 삭제: `terraform/prod/`, `terraform/nonprod/`
- [ ] staging 환경 구성 작성

### 산출물 (예상)
- `terraform/ARCHITECTURE.md`
- `terraform/environments/staging/{base,app,data}/`

---

## 참고: 리소스 분류 기준

| 분류 | 기준 | 배치 | State 분리 이유 |
|------|------|------|----------------|
| **Global** | AWS 계정 전체에 1개 | `global/` | 환경 무관, 거의 안 바뀜 |
| **DNS** | 도메인 단위로 1개 | `dns-zone/` | 글로벌 서비스 |
| **Monitoring** | 전 환경 관측 | `monitoring/` | 크로스환경 |
| **Base (환경별)** | networking + storage | `environments/{env}/base/` | 저변동, 기반 인프라 |
| **App (환경별)** | compute + SG + EIP | `environments/{env}/app/` | 고변동, 배포마다 변경 |
| **Data (환경별)** | RDS | `environments/{env}/data/` | Stateful, 별도 보호 |
