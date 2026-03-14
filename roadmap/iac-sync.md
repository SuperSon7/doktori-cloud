# IaC 동기화 Roadmap

> AWS 실제 인프라와 Terraform 코드 간 갭을 해소하고 전체 리소스를 IaC 관리 하에 두기
>
> 트래킹 시작: 2026-03-09
> 최종 갱신: 2026-03-13

---

## 진행 현황

| Phase | 제목 | 상태 | 완료일 | 비고 |
|:-----:|------|:----:|:-----:|------|
| 0 | [ECR repos 코드화](#phase-0-ecr-repos-코드화) | ✅ Done | 2026-03-13 | 9개 repo + lifecycle policy |
| 1 | [KMS 키 3개 import](#phase-1-kms-키-3개-import) | ✅ Done | 2026-03-14 | prod/staging apply 완료, dev는 Phase 8과 동시 진행 |
| 2 | [chat-observer 인스턴스 코드화](#phase-2-chat-observer-인스턴스-코드화) | ✅ Done | 2026-03-14 | 이미 코드화 완료, EIP 태그 수정은 Phase 7로 |
| 3 | [monitoring 레이어 코드화](#phase-3-monitoring-레이어-코드화) | ✅ Done | 2026-03-14 | 이미 코드화 + state 관리 완료 |
| 4 | [staging k8s 서브넷 등록](#phase-4-staging-k8s-서브넷-등록) | ✅ Done | 2026-03-14 | import + apply 완료 |
| 5 | [IAM Users 코드화](#phase-5-iam-users-코드화) | ✅ Done | 2026-03-14 | Admin 그룹 + 3 users apply 완료 |
| 6 | [잔존 리소스 정리](#phase-6-잔존-리소스-정리) | ✅ Done | 2026-03-14 | testdbsg 삭제 완료 |
| 7 | [컨벤션 정리: 코드 불일치 수정](#phase-7-컨벤션-정리-코드-불일치-수정) | 🔄 In Progress | - | instance_types 동기화, monitoring_ip 삭제 완료. SuperSon7/README/EIP태그 잔여 |
| 8 | [컨벤션 정리: dev "nonprod" → "dev" 전환](#phase-8-컨벤션-정리-dev-nonprod--dev-전환) | ✅ Done | 2026-03-14 | state 마이그레이션 + 서비스 키 rename + apply 완료 |
| 9 | [ECR repo 통합 (이름 정규화)](#phase-9-ecr-repo-통합-이름-정규화) | 🔲 Todo | - | prod-* 별도 repo → 태그 기반 분리 |

---

## Phase 0: ECR repos 코드화

**목표:** 수동 생성된 9개 ECR repo를 `terraform/ecr/` 독립 레이어로 관리

### Checklist
- [x] ECR 실제 설정 확인 (mutability, scan_on_push, lifecycle policy)
- [x] `terraform/ecr/` 디렉토리 생성 (providers.tf, main.tf, variables.tf, outputs.tf)
- [x] 9개 repo + 8개 lifecycle policy import 완료
- [x] scope 태그로 환경 구분 (dev/prod)
- [ ] `terraform plan` — destroy 0 확인
- [ ] `terraform apply` — 태그 반영 + nginx lifecycle policy 추가
- [ ] 커밋 → PR

### 산출물
- `terraform/ecr/providers.tf` — S3 backend, state key: `ecr/terraform.tfstate`
- `terraform/ecr/main.tf` — 9개 repo + lifecycle policy
- `terraform/ecr/variables.tf` — project_name, aws_region
- `terraform/ecr/outputs.tf` — repository_urls, repository_arns

---

## Phase 1: KMS 키 3개 import

**목표:** 기존 수동 생성된 KMS key/alias를 각 환경 base의 storage 모듈로 import

### Checklist
- [x] prod/staging base에서 `create_kms_and_iam = true`로 변경
- [x] storage 모듈 description을 실제에 맞게 수정 (environment 부분 제거)
- [x] prod: KMS key `2ddbf5d2...` + alias + IAM policy import 완료
- [x] staging: KMS key `e30d6af4...` + alias + IAM policy import 완료
- [ ] **dev: Phase 8(nonprod→dev 전환)과 동시 진행** — alias가 `doktori-dev-*`인데 모듈은 `doktori-nonprod-*` 생성하므로 불일치
- [x] plan 검증 — KMS CostCenter 태그 + SSM Name 태그 추가만, destroy 0
- [x] ssm_parameters 모듈에 Name 태그 + ignore_changes(description) 추가
- [x] prod/staging base apply 완료 (2026-03-14)
- [ ] 커밋 → PR (base 변경)

### 산출물 (예상)
- `environments/{dev,prod,staging}/base/main.tf` — `create_kms_and_iam = true`
- `modules/storage/variables.tf` — 필요 시 이름 override 변수

---

## Phase 2: chat-observer 인스턴스 코드화

**목표:** prod VPC의 수동 생성 chat-observer 인스턴스를 prod app compute 모듈에 편입

### Checklist
- [ ] chat-observer 실제 설정 확인 (SG rules, volume, user_data 등)
- [ ] prod app `services` map에 `chat_observer` 추가
- [ ] EC2 인스턴스 + SG + EIP import
- [ ] EIP 태그 수정 (현재 "doktori-staging-nginx-eip"으로 잘못 태깅)
- [ ] plan 검증 — destroy 0 확인
- [ ] 커밋 → PR (app 변경)

### 산출물 (예상)
- `environments/prod/app/main.tf` — chat_observer 서비스 추가, dns_name_map 추가

---

## Phase 3: monitoring 레이어 코드화

**목표:** default VPC의 monitoring 인스턴스 관련 리소스를 `terraform/monitoring/`에 코드화

### Checklist
- [ ] monitoring 인스턴스 실제 설정 상세 확인 (SG, IAM, volume, user_data)
- [ ] `terraform/monitoring/` 디렉토리 생성
- [ ] EC2 인스턴스 + EIP + SG 코드 작성 및 import
- [ ] `doktori-monitoring-ec2-ssm` IAM Role import
- [ ] `doktori-monitoring-loki` S3 bucket import
- [ ] plan 검증 — destroy 0 확인
- [ ] 커밋 → PR

### 산출물 (예상)
- `terraform/monitoring/main.tf` — EC2, EIP, SG, IAM Role, S3
- `terraform/monitoring/providers.tf` — state key: `monitoring/terraform.tfstate`
- `terraform/monitoring/variables.tf`
- `terraform/monitoring/outputs.tf`

---

## Phase 4: staging k8s 서브넷 등록

**목표:** staging VPC에 수동 생성된 k8s 서브넷 2개를 staging base에 등록

### Checklist
- [ ] staging base `subnets` map에 k8s 서브넷 추가
- [ ] `10.2.48.0/24` (k8s-a, ap-northeast-2a) import
- [ ] `10.2.49.0/24` (k8s-b, ap-northeast-2b) import
- [ ] route table association도 확인 및 import
- [ ] k8s-lab에서 base output 참조하도록 연결 검토
- [ ] plan 검증
- [ ] 커밋 → PR (base 변경)

### 산출물 (예상)
- `environments/staging/base/main.tf` — subnets map에 2개 추가

---

## Phase 5: IAM Users 코드화

**목표:** global의 team_members에 누락된 IAM 사용자 추가

### Checklist
- [ ] `doktori-admin` — 역할 확인, admin이라 team_members에 넣을지 별도 관리할지 결정
- [ ] `doktori-cloud-h` — cloud team 소속, team_members에 추가
- [ ] plan 검증
- [ ] 커밋 → PR

### 산출물 (예상)
- `terraform/global/variables.tf` — team_members default에 추가

---

## Phase 6: 잔존 리소스 정리

**목표:** 수동 생성 잔존 리소스 확인 후 삭제 또는 코드화

### Checklist
- [ ] `testdbsg` (prod VPC, sg-071fb4c95e9e4a2f5) — RDS에 연결 안 됨 확인 후 삭제
- [ ] 미연결 EIP 54.116.67.87 — chat-observer에 연결됨 (Phase 2에서 처리)
- [ ] `doktori-dev-ec2-ssm` IAM Role — nonprod role과 중복인지 확인
- [ ] `doktori-batch-scheduler-role` IAM Role — 사용 여부 확인
- [ ] `My Monthly Cost Budget` ($300) — 코드화 또는 삭제
- [ ] nonprod VPC Endpoints 존재 여부 재확인 (이전 세션에서 발견)

### 산출물 (예상)
- AWS 리소스 삭제 (코드 변경 최소)

---

## Phase 7: 컨벤션 정리: 코드 불일치 수정

**목표:** 코드 내 불일치 및 미사용 항목 정리

### Checklist
- [x] ~~prod app `enable_batch_self_stop = true` → `false`~~ — 취소: 실제 EventBridge 배치 작업 있음
- [x] ~~staging `key_name = "doktori-prod"` 확인~~ — 취소: 실제로 prod key 사용 중, 코드=실제 일치
- [x] staging instance_types 코드 vs 실제 동기화 완료 (front→small, api/chat→medium)
- [x] global TODO `SuperSon7` repo 제거 완료
- [x] prod app `monitoring_ip` 미사용 변수 삭제 완료
- [x] dev SSM parameter type 불일치 — Phase 8에서 해결
- [ ] `prod/cdn/` 디렉토리 위치 `environments/` 하위로 이동 검토 — 우선순위 낮음
- [x] README Known Limitations 업데이트 완료
- [ ] chat-observer EIP 태그 수정 — AWS 콘솔에서 수동 변경 필요 (`data.aws_eip`은 read-only)

### 산출물 (예상)
- 각 환경 variables.tf, main.tf 수정
- `terraform/global/main.tf` TODO 제거

---

## Phase 8: 컨벤션 정리: dev "nonprod" → "dev" 전환

**목표:** dev 환경의 var.environment를 "nonprod"에서 "dev"로 통일

### Checklist
- [ ] S3 state 파일 마이그레이션 (nonprod/ → dev/ 복사)
- [ ] `environments/dev/base/variables.tf` — default "nonprod" → "dev"
- [ ] `environments/dev/app/variables.tf` — default "nonprod" → "dev"
- [ ] `environments/dev/base/providers.tf` — backend key 변경
- [ ] `environments/dev/app/providers.tf` — backend key 변경
- [ ] `global/main.tf` — BE team SSM 조건에서 "nonprod" 제거
- [ ] dev base NAT `nat_extra_tags` 하드코딩 수정
- [ ] dev base SSM prefix 하드코딩 제거 (var.environment 사용)
- [ ] dev app S3 ARN 이중 지정 정리
- [ ] `terraform init -reconfigure` (base, app)
- [ ] plan 확인 — recreate 목록 검토
- [ ] **EC2 인스턴스 확장/교체 시점에 맞춰 apply** (리소스 이름 변경 → recreate 발생)

### 주의사항
- var.environment이 리소스 이름에 사용되어 destroy+recreate 발생
- `terraform state mv`로 수동 rename 가능하나 작업량 많음
- EC2 확장 시점에 맞춰 진행하면 다운타임 최소화

### 산출물 (예상)
- `environments/dev/{base,app}/variables.tf` — environment 변경
- `environments/dev/{base,app}/providers.tf` — backend key 변경
- `terraform/global/main.tf` — SSM 조건 수정

---

## Phase 9: ECR repo 통합 (이름 정규화)

**목표:** prod 전용 ECR repo(`prod-*`)를 제거하고 하나의 repo에서 태그로 환경 구분

### Checklist
- [ ] 현재 CI/CD 파이프라인(Backend ci-cd.yaml)의 ECR push 대상 확인
- [ ] repo 통합 계획 수립 (예: `doktori/backend-api:main` for prod)
- [ ] CI/CD 파이프라인 수정 (push/pull 대상 repo 변경)
- [ ] 기존 prod 이미지 마이그레이션 (필요 시)
- [ ] `terraform/ecr/main.tf`에서 prod-* repos 제거
- [ ] 이전 prod-* repos 삭제
- [ ] 전체 배포 파이프라인 검증

### 주의사항
- Backend repo CI/CD와 동시 수정 필요
- 배포 중단 없이 전환하려면 새 repo에 이미지 복제 후 CI/CD 전환 → 이전 repo 삭제 순서

### 산출물 (예상)
- `terraform/ecr/main.tf` — repos 정리
- `Backend/.github/workflows/ci-cd.yaml` — ECR 대상 변경