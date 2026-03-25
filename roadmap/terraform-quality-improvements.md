# Terraform 품질 개선 Roadmap

> CI 안정성, 보안, 구조적 완성도를 업계 베스트 프랙티스 수준으로 끌어올리기
>
> 트래킹 시작: 2026-03-22
>
> 관련 로드맵: [CI Workflow 개선](ci-workflow-improvements.md) (Phase 0~3)

---

## 진행 현황

| Phase | 제목 | 상태 | 완료일 | 비고 |
|:-----:|------|:----:|:-----:|------|
| 0 | [CI Quick Wins](#phase-0-ci-quick-wins) | 🔲 Todo | - | fmt/validate, job 의존성, 죽은 코드 정리 |
| 1 | [CI 안전장치 강화](#phase-1-ci-안전장치-강화) | 🔲 Todo | - | prod 승인 게이트, destroy 보호, 누락 레이어 |
| 2 | [보안 강화](#phase-2-보안-강화) | 🔲 Todo | - | 환경별 Role 분리, SSH key 제거, 보안 스캐닝 |
| 3 | [코드 품질 · 구조 개선](#phase-3-코드-품질--구조-개선) | 🔲 Todo | - | variable validation, app 레이어 분리 |
| 4 | [시크릿 관리 고도화](#phase-4-시크릿-관리-고도화) | 🔲 Todo | - | Secrets Manager, 자동 로테이션 |

---

## Phase 0: CI Quick Wins

**목표:** 난이도 낮고 효과 높은 CI 개선 즉시 적용

### Checklist
- [ ] CI에 `terraform fmt -check` 단계 추가 (PR plan job 앞에 실행)
- [ ] CI에 `terraform validate` 단계 추가 (init 직후 실행)
- [ ] `apply-data` job에 `apply-app` 의존성 추가 (`needs: [detect-changes, apply-base, apply-app]`)
- [ ] PR plan job의 미사용 exitcode output 제거 (죽은 코드 정리)
- [ ] PR plan 코멘트를 `behavior: update` 방식으로 변경 (누적 방지)
- [ ] `cloud-pr-alert.yml` Discord ID 변수 참조 오류 수정 (`DISCORD_ID_ELLA`, `DISCORD_ID_BRUNI` 미정의)

### 산출물 (예상)
- `.github/workflows/terraform.yml` — fmt/validate 단계, job 의존성 수정
- `.github/workflows/cloud-pr-alert.yml` — Discord ID 변수 수정

---

## Phase 1: CI 안전장치 강화

**목표:** 프로덕션 apply 안전성 확보 + CI 커버리지 100%

### Checklist
- [ ] GitHub Environments + required reviewers로 prod apply 수동 승인 게이트 추가
- [ ] `terraform-staging.yml` apply job에 destroy 감지 보호 로직 추가 (`terraform.yml`과 동일 패턴)
- [ ] CI paths 트리거에 누락 레이어 추가: `global/`, `monitoring/`, `dns-zone/`, `ecr/`, `prod/cdn/`
- [ ] detect-changes 매트릭스에 위 레이어 포함
- [ ] `nginx-build.yml` Role ARN을 `secrets.AWS_ROLE_ARN`으로 통일 (직접 조합 제거)
- [ ] PR에서 base+app 동시 변경 시 app plan skip 로직 추가 (plan-all.sh 패턴 활용)

### 산출물 (예상)
- `.github/workflows/terraform.yml` — 승인 게이트, 누락 레이어, skip 로직
- `.github/workflows/terraform-staging.yml` — destroy 보호
- `.github/workflows/nginx-build.yml` — Role ARN 통일

### 참조
- [CI Workflow 개선 Phase 0](ci-workflow-improvements.md#phase-0-ci-커버리지-확대) — 누락 레이어 관련
- [CI Workflow 개선 Phase 1](ci-workflow-improvements.md#phase-1-baseapp-pr-자동-순차-처리) — base+app PR 순차 처리

---

## Phase 2: 보안 강화

**목표:** 최소 권한 원칙 적용 + 보안 자동 스캐닝 도입

### Checklist
- [ ] 환경별 AWS OIDC Role 분리 (`AWS_ROLE_ARN_PROD`, `AWS_ROLE_ARN_DEV`)
- [ ] Terraform Role IAM 권한 세분화 (현재 `Resource: "*"` → 리소스 ARN 지정)
- [ ] `monitoring-cd.yaml` SSH key 방식 → SSM Session Manager 기반으로 전환
- [ ] CI에 tflint 또는 checkov 보안 스캐닝 단계 추가
- [ ] State bucket 암호화를 S3 관리형(AES256) → KMS CMK로 전환

### 산출물 (예상)
- `terraform/global/` — 환경별 OIDC Role 분리
- `.github/workflows/terraform.yml` — Role ARN 분기 처리
- `.github/workflows/monitoring-cd.yaml` — SSH → SSM 전환
- `terraform/backend/` — KMS CMK 설정

### 참조
- [CI Workflow 개선 Phase 3](ci-workflow-improvements.md#phase-3-gha-role-권한-관리-체계화) — GHA Role 권한 체계화

---

## Phase 3: 코드 품질 · 구조 개선

**목표:** 모듈 안정성 향상 + 대형 레이어 분리

### Checklist
- [ ] 주요 모듈 variables.tf에 `validation` 블록 추가 (CIDR 형식, instance_type 허용 목록 등)
- [ ] prod/app 레이어 분리 검토 (현재 646줄 → compute/k8s/routing 분리 가능성 평가)
- [ ] `terraform state rm` 기반 prevent_destroy 우회 제거 → `prevent_destroy = false` 임시 변경 방식으로 통일
- [ ] modules 변경 시 영향받는 환경만 선별 plan/apply하는 로직 검토 (현재: 전체 환경 대상)

### 산출물 (예상)
- `terraform/modules/*/variables.tf` — validation 블록 추가
- `terraform/environments/prod/app/` — 분리 시 k8s/, routing/ 등
- `.github/workflows/terraform-staging.yml` — state rm 제거

---

## Phase 4: 시크릿 관리 고도화

**목표:** 시크릿 자동 로테이션 + 감사 추적

### Checklist
- [ ] DB 비밀번호를 SSM Parameter Store → AWS Secrets Manager로 이관
- [ ] Secrets Manager 자동 로테이션 Lambda 설정 (RDS 연동)
- [ ] K8s External Secrets Operator가 Secrets Manager를 소스로 사용하도록 변경
- [ ] SOPS 도입 검토: 시크릿 초기값을 암호화된 상태로 Git 관리 가능 여부 평가

### 산출물 (예상)
- `terraform/modules/database/` — Secrets Manager 리소스 추가
- `k8s/manifests/` — ExternalSecret CRD 수정

### 참조
- [SOPS 암호화 로드맵](sops-encryption.md) — 관련 계획

---

## 분석 근거

### CI 문제점 진단 (15건)

| 심각도 | 건수 | 주요 내용 |
|--------|------|----------|
| 높음 | 5 | 누락 레이어, apply 의존성, 단일 Role, destroy 보호 미비 |
| 중간 | 6 | concurrency, base+app plan 실패, SSH key, state rm 우회 |
| 낮음 | 4 | 코멘트 누적, 상대경로, Discord 변수 오류 |

### 업계 비교 결과

| 항목 | 평가 | 비고 |
|------|------|------|
| 디렉토리 구조 | ⭐⭐⭐⭐⭐ | 레이어 분리 + 모듈화 우수 |
| 모듈 재사용성 | ⭐⭐⭐⭐⭐ | for_each map, moved 블록 활용 |
| State 관리 | ⭐⭐⭐⭐ | S3+DynamoDB 표준, KMS CMK 미적용 |
| CI/CD | ⭐⭐⭐⭐ | 순서 보장 우수, 승인 게이트·정적 분석 부재 |
| 보안 | ⭐⭐⭐ | OIDC 좋으나 단일 Role, SSH key 혼재 |
| 시크릿 관리 | ⭐⭐⭐ | SSM 껍데기 패턴 실용적, 로테이션 없음 |

### 출처
- HashiCorp Standard Module Structure, AWS Prescriptive Guidance
- Gruntwork Infrastructure Live, Cloud Posse Best Practices
- Google Cloud Terraform Best Practices
- Spacelift / Terrateam CI/CD 패턴