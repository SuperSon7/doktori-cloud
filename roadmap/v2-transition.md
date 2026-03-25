# Cloud Infra v2 Transition Roadmap

> MVP → v2 전환: 브랜치 정리, 인프라 구조 개선, 배포 안정화
>
> 트래킹 시작: 2026-03-08

---

## 진행 현황

| Phase | 제목 | 상태 | 완료일 | 비고 |
|:-----:|------|:----:|:-----:|------|
| 0 | [브랜치 정리 + MVP 태그](#phase-0-브랜치-정리--mvp-태그) | ✅ Done | 2026-03-08 | MVP 기준점 확정 |
| 1 | [Dev 배포 파이프라인 수정](#phase-1-dev-배포-파이프라인-수정) | 🔄 In Progress | - | SSM 태그 불일치 해결 |
| 2 | [Remote 브랜치 정리](#phase-2-remote-브랜치-정리) | 🔲 Todo | - | 팀원 확인 후 진행 |
| 3 | [nonprod → dev 리네이밍](#phase-3-nonprod--dev-리네이밍) | 🔲 Todo | - | terraform state mv 필요 |
| 4 | [Dev Private Subnet 전환 완료](#phase-4-dev-private-subnet-전환-완료) | 🔲 Todo | - | VPN + SSM 연결 검증 |

---

## Phase 0: 브랜치 정리 + MVP 태그

**목표:** MVP 기준점 확정, 불필요한 브랜치 정리

### Checklist
- [x] `feature/migration-loadtest` → main 머지
- [x] `feature/monitoring` → main 머지 (충돌 해결)
- [x] `feature/terraform` → main 머지 (충돌 해결)
- [x] `feature/cicd-ssm` → ssm-db-access.md만 cherry-pick 후 로컬 삭제
- [x] `feature/terraform-state-split` 로컬 삭제 (이미 머지됨)
- [x] `feature/loadtest`, `feature/account-migration` 로컬 삭제 (이미 머지됨)
- [x] `git tag -a mvp` 생성 + push
- [x] main push

### 산출물
- `tag: mvp` — MVP 기준 스냅샷

---

## Phase 1: Dev 배포 파이프라인 수정

**목표:** dev 서버 private 서브넷 이동 후 CI/CD 배포 정상화

### Checklist
- [x] 원인 분석: SSM 타겟 태그 불일치 (`Service=app` vs `Service=dev_app`)
- [x] `terraform/environments/dev/app/main.tf` — dev_app 태그에 `Service = "app"` 추가
- [ ] `terraform apply` 후 태그 반영 확인
- [ ] CI/CD 배포 재실행하여 SSM 타겟 매칭 확인
- [ ] private 서브넷에서 SSM Agent 연결 정상 확인 (NAT 경유)

### 산출물
- `terraform/environments/dev/app/main.tf` — Service 태그 수정

---

## Phase 2: Remote 브랜치 정리

**목표:** 머지 완료된 remote 브랜치 삭제

### Checklist
- [ ] 팀원에게 브랜치 정리 사전 공유
- [ ] `origin/feature/cicd-ssm` 삭제
- [ ] `origin/feature/loadtest` 삭제
- [ ] `origin/feature/migration-loadtest` 삭제
- [ ] `origin/feature/monitoring` 삭제
- [ ] `origin/feature/prodadd` 삭제
- [ ] `origin/feature/terraform-state-split` 삭제

---

## Phase 3: nonprod → dev 리네이밍

**목표:** terraform 코드의 environment 네이밍 통일 (nonprod → dev)

### Checklist
- [ ] `terraform state mv`로 기존 state key 마이그레이션
- [ ] 변수값 `nonprod` → `dev` 변경
- [ ] `terraform plan`으로 destroy 없이 in-place update만 발생하는지 확인
- [ ] SG name, IAM role name 등 force replacement 여부 사전 체크

---

## Phase 4: Dev Private Subnet 전환 완료

**목표:** dev 인프라를 private 서브넷으로 완전 이전, VPN 기반 접근

### Checklist
- [ ] dev_app `subnet_key`를 `public` → `private_app`으로 변경
- [ ] NAT 인스턴스를 통한 아웃바운드 정상 확인
- [ ] SSM Agent 연결 확인 (NAT 경유 or VPC Endpoint 추가)
- [ ] VPN 접근 경로 검증 (SSH, 서비스 포트)
- [ ] CI/CD 배포 E2E 테스트
