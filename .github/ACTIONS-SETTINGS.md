# GitHub Actions 설정

GitHub Actions 설정은 공개 구성값인 **Variables**와 인증값인 **Secrets**를 구분한다.
`NEXT_PUBLIC_*` 값은 Next.js 빌드 결과에 포함되므로 Secret으로 취급하지 않는다.

## 공통 Repository Variables

`doktori-frontend`, `doktori-backend`, `doktori-ai`, `doktori-cloud`에 등록한다.

| Name | Value |
| --- | --- |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::246477585940:role/doktori-gha-deploy` |
| `ECR_REGISTRY` | `246477585940.dkr.ecr.ap-northeast-2.amazonaws.com` |

각 레포의 `DISCORD_WEBHOOK_URL`은 Repository Secret으로 유지한다.

## 공통 Discord 액션

Discord payload 생성과 webhook 전송은 Cloud 레포의
`.github/actions/discord-notify` composite action에서 관리한다.
AI, Backend, Frontend 레포는 다음 공개 액션을 호출한다.

```yaml
uses: SuperSon7/doktori-cloud/.github/actions/discord-notify@main
```

공통 액션 변경은 Cloud 레포에 먼저 반영한 다음 서비스 레포 workflow를 반영한다.
기본값으로 Discord 전송 실패는 빌드나 배포 성공 여부를 바꾸지 않고 Actions warning으로 남긴다.
Delivery 실패를 job 실패로 취급해야 하는 호출만 `fail-on-error: "true"`를 지정한다.

## Frontend

### Repository Variables

Firebase 웹 앱 설정을 모든 환경에서 공유할 때 Repository Variable로 등록한다.

| Name | Value |
| --- | --- |
| `NEXT_PUBLIC_FIREBASE_API_KEY` | `AIzaSyDbVyJOPCt_ihDidU_FCJzWPlzlnP9Gp6s` |
| `NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN` | `doktori-dea34.firebaseapp.com` |
| `NEXT_PUBLIC_FIREBASE_PROJECT_ID` | `doktori-dea34` |
| `NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET` | `doktori-dea34.firebasestorage.app` |
| `NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID` | `562655660288` |
| `NEXT_PUBLIC_FIREBASE_APPID` | `1:562655660288:web:6b917ae79a34444b0f4be5` |
| `NEXT_PUBLIC_FIREBASE_VAPID_KEY` | Firebase Console의 Cloud Messaging 웹 푸시 인증서 |
| `NEXT_PUBLIC_CHAT_WS_PATH` | `/ws/chat` |
| `DISCORD_ID_GREEN` | 선택 사항: Discord 리뷰어 사용자 ID |

Firebase 프로젝트를 환경별로 분리하면 같은 이름을 각 Environment Variable로 등록한다.

### Environments

`dev`, `staging`, `prod`를 생성한다. 각 Environment에서 같은 변수명을 사용한다.

| Variable | dev | staging | prod |
| --- | --- | --- | --- |
| `NEXT_PUBLIC_API_BASE_URL` | 환경 생성 후 입력 | 환경 생성 후 입력 | `https://api.doktori.cloud/api` |
| `NEXT_PUBLIC_CHAT_BASE_URL` | 환경 생성 후 입력 | 환경 생성 후 입력 | `https://api.doktori.cloud` |
| `NEXT_PUBLIC_GA_ID` | 선택 사항 | 선택 사항 | `G-MQVK50NHRH` |
| `NEXT_PUBLIC_SENTRY_DSN` | 선택 사항 | 선택 사항 | 선택 사항: Sentry Public DSN |

`prod` Environment에 다음 배포 구성값도 등록한다.

| Name | Value |
| --- | --- |
| `FRONTEND_TARGET_GROUP_ARN` | `arn:aws:elasticloadbalancing:ap-northeast-2:246477585940:targetgroup/doktori-prod-front-tg/67add13860c80093` |
| `CODEDEPLOY_REVISION_BUCKET` | `doktori-prod-frontend-codedeploy-revisions-246477585940` |
| `CODEDEPLOY_APPLICATION_NAME` | `doktori-frontend-prod` |
| `CODEDEPLOY_DEPLOYMENT_GROUP_NAME` | `doktori-frontend-prod-asg` |
| `STATIC_BUCKET_NAME` | CDN 생성 시 지정한 정적 파일 버킷 이름 |
| `CLOUDFRONT_DISTRIBUTION_ID` | CDN 생성 후 발급된 Distribution ID |

현재 dev와 staging 서비스는 생성되어 있지 않다. 해당 브랜치의 배포를 사용하기 전까지 URL은 임의 값으로 채우지 않는다.

## Backend

`dev`, `prod` Environment를 생성한다.

- `AWS_DEPLOY_ROLE_ARN`, `ECR_REGISTRY`: Repository Variables
- `DISCORD_WEBHOOK_URL`: Repository Secret
- `CLOUD_REPO_PAT`: `prod` Environment Secret
- `DISCORD_ID_ELLA`, `DISCORD_ID_BRUNI`: 선택 사항인 Repository Variables

`CLOUD_REPO_PAT`는 `SuperSon7/doktori-cloud`에 대해 `Contents: Read and write` 권한이 있는 fine-grained PAT를 사용한다.

## AI

`dev`, `prod` Environment를 생성한다.

- `AWS_DEPLOY_ROLE_ARN`, `ECR_REGISTRY`: Repository Variables
- `DISCORD_WEBHOOK_URL`: Repository Secret
- `DISCORD_ID_AI_MASON`: 선택 사항인 Repository Variable

## Cloud

### Repository Variables

| Name | Value |
| --- | --- |
| `AWS_ROLE_ARN` | `arn:aws:iam::246477585940:role/doktori-gha-terraform` |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::246477585940:role/doktori-gha-deploy` |
| `ECR_REGISTRY` | `246477585940.dkr.ecr.ap-northeast-2.amazonaws.com` |
| `DISCORD_ID_VANI` | 선택 사항: Discord 리뷰어 사용자 ID |
| `DISCORD_ID_HALAAND` | 선택 사항: Discord 리뷰어 사용자 ID |
| `TERRAFORM_APPLY_ENABLED` | 자동 apply를 활성화할 때만 `true` |

### Repository Secrets

- `DISCORD_WEBHOOK_URL`
- `INFRACOST_API_KEY`

### Environments

- `terraform-shared`
- `terraform-dev`
- `terraform-prod`
- `terraform-staging`
- `staging`

`terraform-*` Environment는 Terraform apply/start/stop/destroy 승인 경계이고, `staging`은 재사용 서비스 배포 workflow의 경계다.

Terraform Actions는 실행 목적별로 나뉘다.

- `terraform.yml`: PR format, validate, security, plan, Infracost
- `terraform-apply.yml`: `main` push 후 layer 의존성 오케스트레이션
- `_terraform-apply.yml`: 단일 layer init, plan, 삭제 방지, apply, 알림
- `terraform-drift.yml`: 정기 drift 감지와 수동 점검

`TERRAFORM_APPLY_ENABLED`가 정확히 `true`인 경우에만 자동 apply가 실행된다.
미설정, 빈 값, 그 외 값은 모두 apply 비활성화로 취급한다.

## 이전 Secrets 정리

새 Variables와 Environments를 등록하고 Actions 실행이 성공한 뒤 다음 이전 Secret을 삭제한다.

- 모든 레포: `AWS_DEPLOY_ROLE_ARN`, `ECR_REGISTRY`
- Cloud: `AWS_ROLE_ARN`
- Frontend: 이름에 `_DEV`, `_STAGING`, `_PROD`가 붙은 `NEXT_PUBLIC_*` 값과 이전 배포 식별자 Secret
- 리뷰어 Discord ID Secret

Webhook, PAT, Infracost token은 Secret으로 유지한다.
