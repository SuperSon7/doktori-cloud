# Environment 태그 통일 Roadmap

> dev 환경의 `var.environment` 값을 `"nonprod"` → `"dev"`로 통일하여 태그 불일치 해소
>
> 트래킹 시작: 2026-03-10

---

## 진행 현황

| Phase | 제목 | 상태 | 완료일 | 비고 |
|:-----:|------|:----:|:-----:|------|
| 0 | [사전 준비](#phase-0-사전-준비) | 🔲 Todo | - | 백업, 다운타임 공지 |
| 1 | [State 마이그레이션](#phase-1-state-마이그레이션) | 🔲 Todo | - | S3 state 파일 경로 변경 |
| 2 | [코드 변경 + Plan](#phase-2-코드-변경--plan) | 🔲 Todo | - | 5개 파일 수정, plan 검증 |
| 3 | [Apply + 검증](#phase-3-apply--검증) | 🔲 Todo | - | base → app 순서 apply |
| 4 | [정리](#phase-4-정리) | 🔲 Todo | - | 임시 조치 제거, 구 state 삭제 |

---

## 배경

- `staging` / `prod`는 변수와 태그 일치 → 정상
- `dev`만 `var.environment = "nonprod"` → default_tags `Environment = "nonprod"`, 서비스 태그 `Environment = "dev"` 혼재
- 실제 장애 발생: IAM 정책 `ssm:resourceTag/Environment = "dev"` vs EC2 역할 태그 `nonprod` 불일치로 SSM AccessDenied
- 인스턴스 확장/교체 시점에 맞춰 진행 예정 (리소스 이름 변경으로 destroy+recreate 발생하므로)

---

## Phase 0: 사전 준비

**목표:** 다운타임 영향 최소화를 위한 사전 작업

### Checklist
- [ ] dev EC2 인스턴스 AMI 스냅샷 생성 (dev_app, dev_ai, dev_ai_batch)
- [ ] 팀에 dev 환경 다운타임 일정 공지
- [ ] recreate 대상 리소스 목록 확인 (`terraform plan` 결과에서 `must be replaced` 항목)

---

## Phase 1: State 마이그레이션

**목표:** S3 state 파일 경로를 `nonprod/` → `dev/`로 이동

### Checklist
- [ ] `aws s3 cp s3://doktori-v2-terraform-state/nonprod/base/terraform.tfstate s3://doktori-v2-terraform-state/dev/base/terraform.tfstate`
- [ ] `aws s3 cp s3://doktori-v2-terraform-state/nonprod/app/terraform.tfstate s3://doktori-v2-terraform-state/dev/app/terraform.tfstate`
- [ ] 복사 후 두 파일 모두 정상인지 `terraform state list`로 확인

---

## Phase 2: 코드 변경 + Plan

**목표:** environment 변수 및 backend key를 `"dev"`로 통일, plan 검증

### Checklist
- [ ] `environments/dev/base/variables.tf:9` — `default = "nonprod"` → `"dev"`
- [ ] `environments/dev/app/variables.tf:9` — `default = "nonprod"` → `"dev"`
- [ ] `environments/dev/base/providers.tf:12` — `key = "nonprod/base/terraform.tfstate"` → `"dev/base/terraform.tfstate"`
- [ ] `environments/dev/app/providers.tf:16` — `key = "nonprod/app/terraform.tfstate"` → `"dev/app/terraform.tfstate"`
- [ ] `global/main.tf:390` — SSM 조건에서 `"nonprod"` 제거 (`"dev"`만 유지)
- [ ] `environments/dev/base` — `terraform init -reconfigure` 성공
- [ ] `environments/dev/app` — `terraform init -reconfigure` 성공
- [ ] `./scripts/plan-all.sh` 실행하여 전체 레이어 plan 확인
- [ ] plan 결과에서 recreate 목록이 Phase 0 예상과 일치하는지 확인

### 산출물 (예상)
- `environments/dev/base/variables.tf` — environment default 변경
- `environments/dev/app/variables.tf` — environment default 변경
- `environments/dev/base/providers.tf` — backend key 변경
- `environments/dev/app/providers.tf` — backend key 변경
- `global/main.tf` — SSM 조건 정리

---

## Phase 3: Apply + 검증

**목표:** base → app 순서로 apply, 서비스 정상 동작 확인

### Checklist
- [ ] `environments/dev/base` — `terraform apply` 완료
- [ ] `environments/dev/app` — `terraform apply` 완료
- [ ] EC2 인스턴스 SSM 접속 테스트 (ella 계정으로 `ssm:StartSession` 성공)
- [ ] 모든 dev EC2 태그가 `Environment = "dev"`인지 확인
- [ ] 서비스 정상 동작 확인 (app, ai 헬스체크)

---

## Phase 4: 정리

**목표:** 임시 조치 및 구 리소스 제거

### Checklist
- [ ] S3에서 구 state 파일 삭제: `s3://doktori-v2-terraform-state/nonprod/` 경로
- [ ] variables.tf의 `# NOTE: "nonprod"` 주석 제거
- [ ] ella IAM 정책에서 임시 추가한 `"nonprod"` 조건 제거 (이미 불필요)
- [ ] dev_app/dev_ai 서비스 태그에서 중복 `Environment = "dev"` 제거 가능 여부 검토 (default_tags와 동일해지므로)