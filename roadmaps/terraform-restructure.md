# Terraform 구조 리팩토링 Roadmap

> 리소스 성격(글로벌/리전/환경종속)에 맞는 디렉토리 배치로 중복 제거 및 관리 효율화
>
> 트래킹 시작: 2026-02-21

---

## 진행 현황

| Phase | 제목 | 상태 | 완료일 | 비고 |
|:-----:|------|:----:|:-----:|------|
| 0 | [잔존물 정리](#phase-0-잔존물-정리) | 🔲 Todo | - | s3/ 디렉토리 삭제 |
| 1 | [DNS 통합](#phase-1-dns-통합) | 🔲 Todo | - | 3곳 → dns-zone/ 1곳으로 |
| 2 | [IAM 중복 제거](#phase-2-iam-중복-제거) | 🔲 Todo | - | global/ vs iam/ 충돌 해소 |
| 3 | [KMS 중복 제거](#phase-3-kms-중복-제거) | 🔲 Todo | - | parameter-store 일원화 |
| 4 | [CloudFront + S3 연동](#phase-4-cloudfront--s3-연동) | 🔲 Todo | - | CF → global/, S3은 기존 유지 |
| 5 | [네이밍 및 문서화](#phase-5-네이밍-및-문서화) | 🔲 Todo | - | 컨벤션 통일 + 의존성 다이어그램 |

---

## 현재 구조 vs 목표 구조

### Before (현재)

```
terraform/
├── backend/           # State 관리
├── dns-zone/          # Hosted Zone + MX/TXT/DKIM
├── global/            # GitHub OIDC, IAM Groups, Budget
├── iam/               # GitHub OIDC (중복!), GHA Role, IAM Users
├── monitoring/        # 모니터링 EC2
├── parameter-store/   # KMS + Policy
├── _shared/           # tfvars (활용 저조)
├── s3/                # ← 잔존물 (main.tf 없음)
├── nonprod/
│   ├── compute/
│   ├── networking/
│   ├── storage/       # S3 + ECR + KMS(중복)
│   └── dns/           # dev.doktori.kr 레코드
└── prod/
    ├── compute/
    ├── networking/
    ├── storage/       # S3 + ECR + KMS(중복)
    └── dns/           # doktori.kr 레코드
```

### After (목표)

```
terraform/
├── backend/           # State 관리 (유지)
├── dns-zone/          # Hosted Zone + 모든 DNS 레코드 (통합)
├── global/            # GitHub OIDC, IAM, Budget, CloudFront (통합)
├── monitoring/        # 모니터링 EC2 (유지)
├── parameter-store/   # KMS + Policy (일원화)
├── _shared/           # tfvars
├── nonprod/
│   ├── compute/
│   ├── networking/
│   └── storage/       # S3 + ECR (KMS 제거)
└── prod/
    ├── compute/
    ├── networking/
    └── storage/       # S3 + ECR (KMS 제거)
```

**삭제 대상:** `s3/`, `iam/`, `nonprod/dns/`, `prod/dns/`

---

## Phase 0: 잔존물 정리

**목표:** 사용하지 않는 `terraform/s3/` 디렉토리 제거

### 배경
- v1에서 S3를 관리하던 디렉토리가 v2에서 `nonprod/storage/`, `prod/storage/`로 이전됨
- `main.tf`가 없고 `plan.out`(바이너리), `terraform.tfvars`만 존재
- 실제 리소스를 관리하는 state 없음 → 안전하게 삭제 가능

### Checklist
- [ ] `terraform/s3/` 디렉토리에 연결된 remote state 없음 확인
- [ ] `terraform/s3/` 디렉토리 삭제
- [ ] git에서 제거 및 커밋

### 산출물 (예상)
- (삭제만 수행)

---

## Phase 1: DNS 통합

**목표:** 3곳에 분산된 DNS 레코드를 `dns-zone/` 1곳으로 통합

### 배경 (왜 통합하는가)
- Route53은 **글로벌 서비스** — 리전에 종속되지 않음
- `nonprod/dns/`, `prod/dns/` 모두 **동일한 Hosted Zone**(doktori.kr)의 레코드를 조작
- 환경별로 분리해도 blast radius 격리 효과 없음 (같은 zone이라 어차피 상호 영향 가능)
- `remote_state` 참조가 중복으로 발생
- 전체 DNS 현황을 한 눈에 볼 수 없음

### 현재 레코드 분포

| 파일 | 레코드 |
|------|--------|
| `dns-zone/main.tf` | MX, TXT(google-site-verification), DKIM |
| `nonprod/dns/main.tf` | `dev.doktori.kr` → dev_app_ip, `monitoring.doktori.kr` → monitoring_ip |
| `prod/dns/main.tf` | `doktori.kr` → nginx_eip, `www.doktori.kr` → nginx_eip |

### Checklist
- [ ] `dns-zone/main.tf`에 nonprod/dns, prod/dns 레코드를 추가
- [ ] 기존 nonprod/dns, prod/dns의 state를 `terraform state mv`로 dns-zone state에 이동
- [ ] nonprod/dns, prod/dns의 remote_state 참조를 제거하고 dns-zone 내부 직접 참조로 변경
- [ ] `terraform plan`으로 변경 없음(no changes) 확인
- [ ] `nonprod/dns/`, `prod/dns/` 디렉토리 삭제
- [ ] dns-zone을 참조하는 다른 모듈이 있는지 확인 후 업데이트

### 산출물 (예상)
- `terraform/dns-zone/main.tf` — 모든 DNS 레코드 통합
- `terraform/dns-zone/variables.tf` — IP 변수 추가 (nginx_eip, dev_app_ip, monitoring_ip)

---

## Phase 2: IAM 중복 제거

**목표:** `global/`과 `iam/`에 분산된 IAM 리소스를 `global/`로 통합

### 배경 (왜 문제인가)
- **동일 리소스 중복 생성 위험:** `global/main.tf`과 `iam/main.tf` 모두 `aws_iam_openid_connect_provider.github_actions` 선언
- GitHub OIDC Provider는 AWS 계정당 1개만 존재 가능 → state 충돌 또는 apply 실패 가능
- IAM은 글로벌 서비스 → `global/`에서 일원화하는 것이 자연스러움

### 중복 현황

| 리소스 | global/main.tf | iam/main.tf |
|--------|:-:|:-:|
| GitHub OIDC Provider | O | O (중복) |
| GitHub Actions Deploy Role + ECR/SSM Policy | O | O (설정 다를 수 있음) |
| IAM Groups (cloud/be/fe/ai) | O | - |
| IAM Users | O | O |

### Checklist
- [ ] `iam/main.tf`와 `global/main.tf`의 실제 state 비교 (어느 쪽이 live 리소스를 관리 중인지 확인)
- [ ] live 리소스를 관리하는 쪽을 기준으로 통합 방향 결정
- [ ] `terraform state mv`로 리소스를 `global/` state로 이동
- [ ] `global/main.tf`에 누락된 리소스(있다면) 추가
- [ ] `terraform plan`으로 no changes 확인
- [ ] `iam/` 디렉토리 삭제

### 산출물 (예상)
- `terraform/global/main.tf` — IAM 리소스 통합

---

## Phase 3: KMS 중복 제거

**목표:** Parameter Store용 KMS Key를 `parameter-store/`에서만 관리

### 배경
- 현재 KMS Key + IAM Policy가 3곳에서 생성됨:
  - `parameter-store/main.tf` — 독립 KMS
  - `nonprod/storage/main.tf` — dev용 KMS (별도)
  - `prod/storage/main.tf` — prod용 KMS (별도)
- KMS Key는 환경별로 분리하는 것이 보안상 맞으나, 현재 `parameter-store/`와 `*/storage/`에서 이중 생성
- storage 모듈에서 KMS를 빼고 `parameter-store/`의 output을 참조하도록 변경

### Checklist
- [ ] 각 KMS Key가 실제로 어떤 리소스에서 사용 중인지 확인
- [ ] `parameter-store/`의 KMS를 환경별로 생성하도록 수정 (또는 환경별 parameter-store state 분리)
- [ ] `nonprod/storage/`, `prod/storage/`에서 KMS Key, KMS Alias, Parameter Store Policy 제거
- [ ] storage 모듈에서 `parameter-store`의 remote_state 또는 variable로 KMS ARN 참조
- [ ] `terraform plan`으로 no changes 확인

### 산출물 (예상)
- `terraform/parameter-store/main.tf` — 환경별 KMS 통합
- `terraform/nonprod/storage/main.tf` — KMS 관련 코드 제거
- `terraform/prod/storage/main.tf` — KMS 관련 코드 제거

---

## Phase 4: CloudFront + S3 연동

**목표:** CloudFront를 `global/`에 배치하고 기존 S3와 연동

### 배경
- **CloudFront**: 글로벌 서비스 (엣지 로케이션 기반) → `global/`
- **S3**: 리전 서비스 (`ap-northeast-2`) → 기존 `nonprod/storage/`, `prod/storage/` 유지
- ACM 인증서는 CloudFront용으로 `us-east-1`에 생성 필요
- CloudFront → S3 Origin 연결 시 `terraform_remote_state`로 버킷 정보 참조

### Checklist
- [ ] `global/cloudfront.tf` 작성 (CloudFront Distribution + OAC)
- [ ] `us-east-1` ACM 인증서 리소스 추가 (별도 provider alias)
- [ ] S3 storage 모듈에서 버킷 ARN/domain output 내보내기
- [ ] CloudFront에서 S3 remote_state 참조로 Origin 설정
- [ ] S3 bucket policy에 CloudFront OAC 허용 추가
- [ ] `terraform plan` 검증 및 apply

### 산출물 (예상)
- `terraform/global/cloudfront.tf` — CloudFront Distribution
- `terraform/global/acm.tf` — us-east-1 ACM 인증서
- `terraform/prod/storage/outputs.tf` — 버킷 정보 output 추가

---

## Phase 5: 네이밍 및 문서화

**목표:** S3 네이밍 컨벤션 통일 + 모듈 의존성 문서화

### 배경
- S3 네이밍 불일치:
  - nonprod: `doktori-v2-${environment}` (프리픽스 기반 통합 버킷)
  - prod: `doktori-${environment}-images`, `doktori-${environment}-db-backup` (용도별 분리)
- 모듈 간 의존성이 `terraform_remote_state`로 암묵적 연결되어 있어 전체 그림 파악 어려움

### Checklist
- [ ] S3 네이밍 규칙 결정 및 통일 (rename 필요 시 recreate 고려)
- [ ] 모듈 간 의존성 다이어그램 작성
- [ ] `_shared/` 디렉토리 활용 방안 결정 (auto.tfvars 또는 삭제)
- [ ] 구조 변경 내역 CHANGELOG 작성

### 산출물 (예상)
- `terraform/ARCHITECTURE.md` — 의존성 다이어그램 + 모듈 설명
- `terraform/_shared/` — 정리 또는 삭제

---

## 참고: 리소스 분류 기준

| 분류 | 기준 | 배치 | 예시 |
|------|------|------|------|
| **글로벌 서비스** | AWS 계정 전체에 1개 | `global/` | IAM, CloudFront, Budget |
| **글로벌 (DNS)** | 도메인 단위로 1개 | `dns-zone/` | Route53 Zone + 모든 레코드 |
| **리전 + 환경종속** | 환경마다 별도 리소스 | `{env}/` 하위 | VPC, EC2, S3, ECR |
| **공유 인프라** | 환경 공통, 독립 운영 | 독립 디렉토리 | monitoring, backend |

### 핵심 원칙
> **같은 AWS 리소스를 조작하는 코드는 한 곳에 모은다.**
> - 같은 Hosted Zone → dns-zone/ 1곳
> - 같은 OIDC Provider → global/ 1곳
> - 환경별로 다른 VPC/EC2 → nonprod/, prod/ 분리 유지