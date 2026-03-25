# Terraform CI Workflow 개선 Roadmap

> CI/CD 파이프라인의 안정성·커버리지·자동화 수준을 높여 수동 개입 최소화
>
> 트래킹 시작: 2026-03-17

---

## 진행 현황

| Phase | 제목 | 상태 | 완료일 | 비고 |
|:-----:|------|:----:|:-----:|------|
| 0 | [CI 커버리지 확대](#phase-0-ci-커버리지-확대) | 🔄 In Progress | - | monitoring, global, dev/cdn 등 누락 폴더 CI 포함 |
| 1 | [base/app PR 자동 순차 처리](#phase-1-baseapp-pr-자동-순차-처리) | 🔲 Todo | - | base 변경 감지 시 base apply → app plan 순차 실행 |
| 2 | [동시 PR state lock 충돌 방지](#phase-2-동시-pr-state-lock-충돌-방지) | 🔲 Todo | - | concurrency group으로 레이어별 직렬화 |
| 3 | [GHA Role 권한 관리 체계화](#phase-3-gha-role-권한-관리-체계화) | 🔲 Todo | - | 새 서비스 도입 시 권한 누락 방지 |

---

## Phase 0: CI 커버리지 확대

**목표:** CI가 모든 Terraform 폴더를 plan/apply 대상으로 커버

### 현황
- `plan-all.sh`에서 `monitoring`이 `environments/` 하위에서 찾아 "directory not found" skip
- `dev/cdn` 레이어가 목록에 누락
- `staging/k8s-lab`은 CI 대상 아님 (제외 유지)

### Checklist
- [x] `plan-all.sh`에 `dev/cdn` 레이어 추가
- [x] `plan-all.sh`에서 `monitoring`을 `global`과 같이 `terraform/monitoring/` 직접 경로로 처리
- [ ] `.github/workflows/terraform.yml`의 detect-changes에 `monitoring`, `dev/cdn` 경로 추가
- [ ] CI에서 `plan-all.sh` 실행 후 모든 레이어가 plan 결과 출력되는지 확인

### 산출물
- `scripts/plan-all.sh` — 수정 완료
- `.github/workflows/terraform.yml` — detect-changes 수정 필요

---

## Phase 1: base/app PR 자동 순차 처리

**목표:** base output 변경이 포함된 PR에서 app layer plan이 실패하지 않도록 자동화

### 문제
- 현재: base에 새 output 추가 시 별도 PR 분리 필요 (CLAUDE.md 규칙)
- 한 PR에 base+app 변경이 있으면 CI plan에서 app 검증 불가 (remote state에 새 output 없음)

### Checklist
- [ ] CI workflow에서 base changes 감지 로직 추가
- [ ] base 변경 있으면 base apply 먼저 실행 → app plan 순차 실행하는 job 의존성 구성
- [ ] base-only 변경 PR과 base+app 혼합 PR 모두 테스트
- [ ] CLAUDE.md의 "base 변경 시 PR 분리 필수" 규칙을 자동화 반영으로 업데이트

### 산출물 (예상)
- `.github/workflows/terraform.yml` — job 의존성 수정

---

## Phase 2: 동시 PR state lock 충돌 방지

**목표:** 여러 PR이 동시에 CI를 트리거해도 state lock 경합 없이 안정적으로 실행

### 문제
- 같은 레이어를 동시에 plan/apply하면 DynamoDB state lock 경합 → 대기 또는 실패
- 다른 레이어끼리는 독립이므로 불필요한 대기 방지 필요

### Checklist
- [ ] GitHub Actions `concurrency` group을 레이어별로 설정 (e.g. `terraform-prod-base`)
- [ ] 같은 레이어 PR은 직렬화, 다른 레이어 PR은 병렬 실행 확인
- [ ] lock 대기 timeout 시 명확한 에러 메시지 출력

### 산출물 (예상)
- `.github/workflows/terraform.yml` — concurrency group 추가

---

## Phase 3: GHA Role 권한 관리 체계화

**목표:** 새 AWS 서비스 도입 시 GHA OIDC Role 권한 누락을 사전에 방지

### 문제
- ELB/ASG 등 새 서비스 추가할 때마다 GHA role에 수동으로 권한 추가 필요
- 권한 누락 시 CI apply 실패 → 원인 파악에 시간 소요

### Checklist
- [ ] GHA OIDC Role의 현재 권한 목록 정리
- [ ] 모듈별 필요 IAM 권한을 모듈 README 또는 변수 주석에 명시
- [ ] GHA Role 권한을 Terraform으로 관리 (global/ 레이어)하여 코드 리뷰 가능하게

### 산출물 (예상)
- `terraform/global/gha-role.tf` — GHA OIDC Role 권한 Terraform 관리
- 각 모듈 README에 필요 IAM Actions 명시