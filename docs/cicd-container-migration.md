# Backend CI/CD 컨테이너 전환

## 1. 문제 정의

기존 배포 파이프라인의 한계:

```
CI (Gradle Build) → JAR artifact → SCP 전송 → deploy.sh 실행
```

| 문제 | 영향 |
|------|------|
| SSH 키를 GitHub Secrets에 장기 보관 | 키 유출 시 서버 직접 접근 가능 |
| 배포 시마다 SG 22번 포트 열기/닫기 | race condition, 정리 실패 시 포트 노출 |
| Access Key로 SG/Lightsail 조작 | 장기 자격 증명, 회전 관리 필요 |
| JAR 파일 직접 전송 (SCP) | 환경 불일치, "내 로컬에서는 되는데" |
| Prod: Lightsail 단일 인스턴스 | 스케일 제한, IAM Role 미지원 |

## 2. 검토한 대안

### 2-1. 배포 방식 (SSH 대체)

| 방식 | 장점 | 단점 | 평가 |
|------|------|------|------|
| **SSH (현행)** | 단순, 익숙함 | SSH 키 관리, SG 조작 필요, 네트워크 신뢰 모델 | ❌ |
| **SSM Run Command** | SSH 불필요, SG 불필요, 443 아웃바운드만 사용, CloudTrail 감사 | SSM Agent + IAM Instance Profile 필요 | ✅ 채택 |
| **CodeDeploy** | 자동 롤백, 배포 전략 (blue/green) | appspec.yml, 배포그룹, S3 등 추가 인프라. docker pull 하나에 과도 | ❌ 과도 |

### 2-2. 인증 방식

| 방식 | 자격 증명 수명 | 시크릿 수 | 평가 |
|------|--------------|----------|------|
| **Access Key + SSH Key (현행)** | 영구 | 8개+ (키, SG ID, 호스트, 유저명...) | ❌ |
| **OIDC + SSM** | 워크플로당 ~1시간 | 3개 (Role ARN, ECR Registry, Discord) | ✅ 채택 |

**핵심 결정 근거: Zero Trust 원칙**

1. **자격 증명**: 워크플로 실행마다 OIDC로 단명 토큰 교환 → 장기 보관 키 zero
2. **네트워크**: SSH 포트(22)를 열 필요 없음 → 공격 표면 zero
3. **신원 검증**: GitHub repo/branch → OIDC → IAM Role → SSM. 매 단계 명시적 검증
4. **최소 권한**: IAM 조건으로 `Project=doktori` 태그가 있는 인스턴스에만 명령 허용
5. **감사 추적**: CloudTrail에 모든 SSM 명령 기록

### 2-3. 서비스 디스커버리

| 방식 | 장점 | 단점 | 평가 |
|------|------|------|------|
| **Instance ID를 Secrets에 저장** | 단순 | 인스턴스 교체 시 시크릿 업데이트 필요 | ❌ |
| **EC2 태그 기반 타겟팅** | 인스턴스 교체에도 CI/CD 무변경, SSM 네이티브 지원 | 태그 관리 필요 | ✅ 채택 |

## 3. 최종 아키텍처

```
PR → ci (Gradle 빌드 + 체크스타일)
Push develop → ci → build-and-push (ECR) → deploy-dev (SSM → docker compose)
Push main → ci → build-and-push (ECR) → deploy-prod (SSM → docker run × 2)
```

### 인증 흐름

```
GitHub Actions workflow
  ↓ OIDC token 교환
GitHubActions-Deploy-Role (단명 토큰)
  ├── ECR push (빌드 이미지)
  └── SSM SendCommand (배포 명령)
        ↓ 태그 기반 타겟팅
    EC2 Instance (Environment=dev, Service=backend)
    EC2 Instance (Environment=prod, Service=backend-api)
    EC2 Instance (Environment=prod, Service=backend-chat)
```

### EC2 태그 설계

| 인스턴스 | `Environment` | `Service` | 배포 방식 |
|----------|---------------|-----------|-----------|
| Dev (1대) | `dev` | `backend` | `docker compose pull && up -d` |
| Prod API | `prod` | `backend-api` | `docker pull && docker run` |
| Prod Chat | `prod` | `backend-chat` | `docker pull && docker run` |

- `Environment`: Terraform provider `default_tags`로 자동 부여
- `Service`: `compute` 모듈의 `service_tag` 변수로 설정

### Docker 이미지 태그 전략

| 브랜치 | 태그 | 용도 |
|--------|------|------|
| `develop` | `develop` | mutable, 항상 최신 dev |
| `main` | `sha-{7자리}` + `latest` | immutable SHA + mutable latest |

### 캐싱 전략

- Gradle: `actions/setup-java` 캐시 (CI job)
- Docker: GHA cache (`type=gha, mode=max`)
  - `scope=api`, `scope=chat`으로 분리
  - Chat 빌드 시 API 캐시도 참조 (공통 base 스테이지 재사용)
  - `mode=max`: Gradle 의존성 포함 모든 중간 레이어 캐시

## 4. 변경 사항

### 4-1. GitHub Actions Workflow

**파일**: `.github/workflows/ci-cd.yaml`

| Job | 변경 | 내용 |
|-----|------|------|
| `check-source-branch` | 유지 | main PR 시 develop/hotfix/* 검증 |
| `ci` | 수정 | JAR artifact 준비/업로드 단계 삭제 |
| `build-and-push` | 신규 | OIDC 인증 → ECR 로그인 → Buildx → API/Chat 이미지 빌드 & push |
| `deploy-dev` | 신규 | OIDC → SSM SendCommand (docker compose) |
| `deploy-prod` | 신규 | OIDC → SSM SendCommand (API + Chat 병렬) |
| `deploy` (구) | 삭제 | SSH/SCP 기반 배포 전체 제거 |

### 4-2. Terraform (Cloud 레포)

#### `terraform/iam/main.tf`

Deploy Role에 2개 정책 추가:

| 정책 | 권한 | 리소스 범위 |
|------|------|------------|
| `deploy_ecr_push` | `ecr:PutImage`, `ecr:*LayerUpload`, etc. | `arn:aws:ecr:...:repository/doktori/*` |
| `deploy_ssm_command` | `ssm:SendCommand`, `ssm:ListCommandInvocations`, `ssm:GetCommandInvocation` | Document: `AWS-RunShellScript`, Instance: `Project=doktori` 태그 조건 |

#### `terraform/compute/main.tf`

EC2 Role에 2개 정책 추가:

| 정책 | 내용 |
|------|------|
| `AmazonSSMManagedInstanceCore` | SSM Agent 동작에 필요한 관리형 정책 |
| `ecr_pull` | ECR 이미지 pull 권한 (`doktori/*` 리포지토리) |

+ `Service` 태그 추가 (`service_tag` 변수, 기본값 `backend`)

#### `terraform/ecr/` (신규 모듈)

| 리소스 | 내용 |
|--------|------|
| `aws_ecr_repository` | `doktori/backend-api`, `doktori/backend-chat` |
| `aws_ecr_lifecycle_policy` | 최근 10개 이미지 유지 |

## 5. 삭제 가능한 리소스 (향후)

OIDC + SSM 전환 완료 후 정리 대상:

| 리소스 | 이유 |
|--------|------|
| `aws_iam_user.github_action` | Access Key 대신 OIDC 사용 |
| `aws_iam_policy.dev_github_actions` | SG 22번 조작 불필요 |
| `aws_iam_policy.prod_github_actions` | Lightsail 포트 조작 불필요 |
| GitHub Secrets (8개) | SSH 키, Access Key, SG ID, 호스트 IP 등 |

## 6. 적용 순서

```bash
# 1. ECR 레포지토리 생성
cd terraform/ecr
terraform init && terraform apply

# 2. IAM 정책 적용 (Deploy Role에 ECR + SSM 권한)
cd terraform/iam
terraform init && terraform apply

# 3. EC2 Role 업데이트 (SSM Agent + ECR pull)
cd terraform/compute
terraform apply

# 4. GitHub Secrets 설정
#    - AWS_DEPLOY_ROLE_ARN: Deploy Role ARN
#    - ECR_REGISTRY: <account-id>.dkr.ecr.ap-northeast-2.amazonaws.com

# 5. EC2에 SSM Agent 확인
#    Ubuntu 22.04에는 snap으로 설치:
#    sudo snap install amazon-ssm-agent --classic
#    sudo systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent
#    sudo systemctl start snap.amazon-ssm-agent.amazon-ssm-agent

# 6. Backend CI/CD 워크플로 배포 (feature/cicd → develop merge)

# 7. 검증 후 기존 리소스 정리
```

## 7. Secrets 비교

### Before (11개)
```
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
DEV_EC2_HOST, DEV_EC2_SSH_KEY, EC2_USERNAME, AWS_SG_ID_DEV,
PROD_LIGHTSAIL_HOST, PROD_LIGHTSAIL_INSTANCE_NAME, EC2_SSH_KEY,
AWS_DEPLOY_ROLE_ARN, DISCORD_WEBHOOK_URL
```

### After (3개)
```
AWS_DEPLOY_ROLE_ARN
ECR_REGISTRY
DISCORD_WEBHOOK_URL
```
