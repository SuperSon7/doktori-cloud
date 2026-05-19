# Doktori Terraform 인프라

AWS 인프라를 Terraform으로 관리한다. 환경은 디렉터리 기반으로 분리하고, 각 환경은 `base` / `data` / `app` 레이어를 독립 state로 나누어 변경 영향 범위를 제한한다.

현재 운영 기준은 다음과 같다.

- `base`: VPC, 서브넷, NAT 인스턴스, Route53 프라이빗 호스팅 영역, 환경 공통 SSM 파라미터 껍데기
- `data`: RDS, S3, 상태 저장 데이터 서비스, `data`와 `app`이 공유하는 상태 리소스
- `app`: EC2, ASG, ALB/NLB, K8s worker 라우팅, 배포 대상 컴퓨팅 리소스
- `monitoring`: 별도 mgmt VPC, Loki S3, Prometheus/Loki/Grafana EC2
- `global`, `ecr`, `dns_zone`: 계정/리전/도메인 공통 리소스

## 아키텍처

```
                          +--------------------------------+
                          |            global/             |
                          | OIDC, IAM 그룹/역할, Budget    |
                          +---------------+----------------+
                                          |
             +----------------------------+-----------------------------+
             |                            |                             |
      +------v------+              +------v------+              +------v------+
      |  dev/base   |              |staging/base |              | prod/base   |
      | VPC 10.0/16 |              | VPC 10.2/16 |              | VPC 10.1/16 |
      | NAT 1대     |              | NAT 1대     |              | 3 AZ + NAT 3|
      +------+------+              +------+------+              +------+------+
             |                            |                            |
      +------v------+              +------v------+              +------v------+
      |  dev/data   |              |staging/data |              | prod/data   |
      | S3 + SSM    |              | RDS + S3    |              | RDS Proxy   |
      +------+------+              +------+------+              | S3 + Redis  |
             |                            |                     | RabbitMQ    |
      +------v------+              +------v------+              | MongoDB     |
      |  dev/app    |              |staging/app  |              +------+------+
      | app/front/ai|              | nginx+서비스|                     |
      | qdrant/batch|              | 선택 hK8s   |              +------v------+
      +-------------+              +-------------+              | prod/app    |
                                                                 | 프론트 ASG |
      +----------------------------+                             | 공개 ALB   |
      |        monitoring/         |                             | K8s ASG    |
      | mgmt VPC 172.16.0.0/16    |                             | 내부 NLB   |
      | base / data / app          |                             +------+------+
      | dev/prod VPC 피어링        |                                    |
      +----------------------------+                             +------v------+
                                                                 | prod/cdn    |
                                                                 | CloudFront  |
                                                                 | S3 OAC      |
                                                                 +-------------+

      +-------------+       +----------------+       +----------------------+
      | dns_zone/   |       | ecr/           |       | 부하 테스트 루트     |
      | Route53 +   |       | 공용 저장소    |       | staging/prod 러너    |
      | Google WS   |       | dev/prod 태그  |       | 별도 계정            |
      +-------------+       +----------------+       +----------------------+
```

운영 공개 트래픽 흐름:

```
doktori.kr          -> CloudFront -> front.doktori.kr ALB 오리진 -> 프론트 ASG
doktori.kr/api/*    -> CloudFront -> ALB -> K8s worker NodePort 30080 -> NGF
api.doktori.kr      -> ALB 직접 접근 -> K8s worker NodePort 30080 -> NGF
api.doktori.kr/ws/* -> ALB 직접 접근 -> K8s WebSocket 경로
```

## 디렉터리 구조

```
terraform/
├── backend.hcl                    # S3 backend 공통 설정
├── backend/                       # Terraform state S3 버킷 부트스트랩
├── global/                        # 계정 수준 리소스: OIDC, IAM, Budget
├── ecr/                           # 공용 ECR 저장소
├── dns_zone/                      # Route53 Hosted Zone + Google Workspace 레코드
├── modules/
│   ├── networking/                # VPC, 서브넷, NAT 인스턴스, S3 Gateway Endpoint, 선택 Interface Endpoint
│   ├── compute/                   # EC2, SG, IAM Role/Profile, 선택 EIP
│   ├── database/                  # RDS MySQL, Parameter Group, 선택 RDS Proxy
│   ├── storage/                   # S3, 선택 KMS/IAM/ECR
│   ├── ssm-parameters/            # SSM Parameter Store 껍데기 리소스
│   ├── frontend/                  # 공개 ALB + 프론트 ASG
│   └── k8s-cluster/               # K8s master/worker ASG + 내부 NLB
├── environments/
│   ├── dev/
│   │   ├── base/                  # VPC 10.0.0.0/16, NAT, dev SSM/Qdrant 파라미터
│   │   ├── data/                  # dev S3 app 버킷 + S3 SSM 파라미터
│   │   └── app/                   # app, front, ai, ai-qdrant, ai-batch EC2
│   ├── staging/
│   │   ├── base/                  # VPC 10.2.0.0/16
│   │   ├── data/                  # 폐기 가능한 RDS + staging S3
│   │   ├── app/                   # nginx/front/api/chat/ai/data 보조 EC2 + 선택 h-k8s 노드
│   │   ├── loadtest/              # staging VPC 내부 k6 러너
│   │   └── prod-spec.tfvars       # 부하 테스트용 운영 사양 프로파일
│   ├── prod/
│   │   ├── base/                  # VPC 10.1.0.0/16, 3개 AZ의 공개/app/db 서브넷, NAT 3대
│   │   ├── data/                  # RDS Proxy, app S3, CodeDeploy revision 버킷, Redis/RabbitMQ/MongoDB EC2
│   │   ├── app/                   # 프론트 ASG/ALB, K8s ASG/NLB, front/AI/RDS exporter 보조 EC2
│   │   ├── cdn/                   # CloudFront + 정적 S3 + OAC + DNS
│   │   └── loadtest/              # prod VPC k6 러너
│   └── loadtest/                  # 별도 부하 테스트 계정 VPC/러너, 기본 local state
├── monitoring/
│   ├── base/                      # mgmt VPC, NAT/WireGuard, PHZ, VPC 피어링 라우트
│   ├── data/                      # Loki S3 버킷 + 수명주기
│   └── app/                       # 프라이빗 서브넷의 monitoring EC2 + IAM/SG
└── scripts/
    └── assert-clean-plan.sh       # apply 후 clean plan 검증
```

## 사전 준비

- Terraform `>= 1.10.0` (`.github/workflows`는 현재 `1.14.8` 사용)
- 필요한 IAM 권한으로 설정된 AWS CLI
- `doktori-terraform-state` S3 버킷 접근 권한
- CI 방식의 plan JSON 검사를 위한 `jq`

## 빠른 시작

단일 루트 모듈 실행:

```bash
cd terraform/environments/prod/base
terraform init -backend-config=../../../backend.hcl
terraform plan
terraform apply
```

공통 루트 모듈은 backend 설정 파일의 상대 경로가 다르다.

| 루트 유형 | 예시 | backend 설정 |
|-----------|------|--------------|
| 공통 | `terraform/global`, `terraform/ecr`, `terraform/dns_zone` | `../backend.hcl` |
| 모니터링 | `terraform/monitoring/base` | `../../backend.hcl` |
| 환경 | `terraform/environments/prod/app` | `../../../backend.hcl` |
| 독립 부하 테스트 | `terraform/environments/loadtest` | 기본 local state |

검증:

```bash
terraform fmt -check -recursive terraform/
terraform -chdir=terraform/environments/prod/app init -backend=false
terraform -chdir=terraform/environments/prod/app validate
```

현재 로컬 전체 plan 스크립트는 없다. 루트 모듈별로 실행하거나 GitHub Actions PR plan을 사용한다.

## 적용 순서

새 환경 생성 또는 의존성 변경은 아래 순서로 적용한다.

```
backend
-> global
-> ecr
-> dns_zone
-> monitoring/base
-> monitoring/data
-> monitoring/app
-> {env}/base
-> monitoring/base 재적용
-> {env}/data
-> {env}/app
-> prod/cdn
```

`data`와 `app`은 `base` 출력값을 `terraform_remote_state`로 읽으므로 `base`가 먼저 적용되어야 한다. `app`은 S3 버킷, RDS endpoint, CodeDeploy revision 버킷 같은 상태 리소스 출력값을 읽으므로 `data` 이후에 적용한다. `prod/cdn`은 `prod/app` 출력값을 읽는다.

부하 테스트 레이어:

- `staging/loadtest`: staging base 이후 적용
- `prod/loadtest`: prod base 이후 적용
- `environments/loadtest`: 별도 부하 테스트 계정용 독립 VPC이며 기본은 local state

### `base` 변경 시 PR 분리

`base` 레이어에 새 출력값이 추가되거나 기존 출력값 구조가 바뀌면 PR을 분리한다.

```
1. PR #1: base 변경만
   -> merge -> CI 또는 수동 apply로 원격 state 갱신

2. PR #2: data/app/cdn 변경
   -> 새 출력값 참조 가능
```

한 PR에 합치면 하위 레이어 plan이 아직 원격 state에 없는 출력값을 읽다가 실패할 수 있다.

## 상태 관리

| 항목 | 값 |
|------|----|
| Backend | S3 (`doktori-terraform-state`) |
| 잠금 | S3 native lockfile (`use_lockfile = true`) |
| 암호화 | AES-256 S3 SSE |
| 버전 관리 | 활성화 |

각 루트 모듈의 `providers.tf`는 state key만 지정하고, 공통 버킷/리전/lockfile 설정은 `backend.hcl`에서 주입한다.

```
global/terraform.tfstate
ecr/terraform.tfstate
dns_zone/terraform.tfstate
monitoring/base/terraform.tfstate
monitoring/data/terraform.tfstate
monitoring/app/terraform.tfstate
dev/base/terraform.tfstate
dev/data/terraform.tfstate
dev/app/terraform.tfstate
staging/base/terraform.tfstate
staging/data/terraform.tfstate
staging/app/terraform.tfstate
staging/loadtest/terraform.tfstate
prod/base/terraform.tfstate
prod/data/terraform.tfstate
prod/app/terraform.tfstate
prod/cdn/terraform.tfstate
prod/loadtest/terraform.tfstate
```

`backend/` 디렉터리는 state S3 버킷 자체를 관리하는 부트스트랩 루트 모듈이다. `environments/loadtest`에는 별도 S3 backend 예시가 주석으로 남아 있지만 현재 기본은 local state다.

## 환경 비교

| 항목 | dev | staging | prod |
|---|---|---|---|
| VPC CIDR | `10.0.0.0/16` | `10.2.0.0/16` | `10.1.0.0/16` |
| AZ 구성 | 단일 AZ | 단일 AZ 중심 + 보조 서브넷 | 3개 AZ app/db 서브넷 |
| NAT | NAT 인스턴스 1대 | NAT 인스턴스 1대 | NAT 인스턴스 3대 |
| Interface VPC Endpoint | 없음 | 없음 | 없음 |
| S3 Gateway Endpoint | 있음 | 있음 | 있음 |
| 앱 구성 | 프라이빗 EC2: app/front/ai/qdrant/batch | 공개 nginx + 프라이빗 서비스 EC2, 선택 h-k8s | 프론트 ASG/ALB + K8s master/worker ASG/NLB + 보조 EC2 |
| 데이터 구성 | S3만 Terraform 관리, DB는 dev app host 내부 | RDS + S3 | RDS MySQL 8.4 + RDS Proxy + S3 + Redis/RabbitMQ/MongoDB EC2 |
| RDS | 없음 | 폐기 가능, 직접 endpoint | 삭제 보호, GTID 파라미터, RDS Proxy |
| CDN | 없음 | 없음 | CloudFront + S3 OAC |
| 모니터링 피어링 | dev <-> mgmt | 없음 | prod <-> mgmt |
| 비용 제어 | AutoStop 태그, 주간 배치 기본 정지 | 수동 start/stop/scale 워크플로우 | prod 승인 + 보호 리소스 |

`networking` 모듈은 Interface Endpoint를 지원하지만 현재 모든 환경에서 비활성화되어 있다. S3 Gateway Endpoint는 기본 생성된다.

## 네트워크 CIDR 계획

| 네트워크 | CIDR | 비고 |
|---|---:|---|
| dev VPC | `10.0.0.0/16` | 개발 환경 |
| prod VPC | `10.1.0.0/16` | 운영 환경 |
| staging VPC | `10.2.0.0/16` | 폐기 가능한 staging 환경 |
| 독립 부하 테스트 VPC | `10.200.0.0/16` | 별도 부하 테스트 계정/모듈 |
| mgmt VPC | `172.16.0.0/16` | 모니터링과 WireGuard/NAT VPC |
| prod K8s Pod CIDR | `100.64.0.0/16` | Calico pod 네트워크 |
| prod K8s Service CIDR | `198.18.16.0/20` | ClusterIP 범위 |

CIDR 할당 규칙:

- 환경 VPC는 `10.0.0.0/8` 아래에서 서로 겹치지 않는 `/16` 블록을 사용한다.
- mgmt는 `172.16.0.0/16`을 사용하며 Kubernetes Service CIDR와 겹치면 안 된다.
- Kubernetes Pod CIDR는 `100.64.0.0/10` 대역을 사용한다.
- Kubernetes Service CIDR는 `198.18.0.0/15` 아래 작은 `/20` 블록을 사용한다. 향후 `10.x.0.0/16` VPC 확장과 충돌하므로 넓은 `10.96.0.0/12`는 사용하지 않는다.
- 보안 그룹 description은 AWS 콘솔에서 출발지와 목적지를 이해하기 쉽도록 `from <source> to <target/service>` 형태를 유지한다.

## 운영 라우팅과 런타임 구성

### prod/base

- 공개 서브넷: `public`, `public_c`, `public_b`
- App 프라이빗 서브넷: `private_app`, `private_app_c`, `private_app_b`
- DB 프라이빗 서브넷: `private_db_a`, `private_db_c`, `private_db_b`
- NAT 인스턴스: `primary`, `secondary`, `tertiary`
- 프라이빗 호스팅 영역: `prod.doktori.internal`

### prod/data

- RDS MySQL `8.4.8`, `mysql8.4` 파라미터 그룹, 백업 보관 7일
- RDS Proxy 활성화, `db-proxy.prod.doktori.internal`이 proxy를 가리킴
- App S3 버킷은 `/images/*` prefix만 공개 읽기 허용
- 프론트 CodeDeploy revision 버킷은 `prevent_destroy` 적용
- Redis/RabbitMQ/MongoDB는 DB 서브넷의 자체 관리 EC2로 운영
- `enable_data_ha = false`가 기본값이며, true로 바꾸면 Redis/RabbitMQ가 3개 AZ 노드와 Sentinel/quorum 클러스터 입력값으로 확장된다.

### prod/app

- `frontend` 모듈: 공개 ALB, 프론트 ASG, HTTP listener와 target group
- `api.doktori.kr`, `front.doktori.kr`용 HTTPS listener와 ACM 검증
- 경로 라우팅: `/api/*`, `/ws/*`는 K8s worker NodePort `30080`으로 전달
- `k8s-cluster` 모듈: master ASG desired 3, worker ASG desired 4/min 2/max 6, 내부 NLB
- 보조 compute: front, AI, RDS monitoring exporter EC2
- 프론트 ASG 배포용 CodeDeploy 애플리케이션/배포 그룹

### prod/cdn

- `doktori.kr`, `www.doktori.kr`용 CloudFront 배포
- Origin Access Control을 사용하는 정적 S3 오리진
- `front.doktori.kr` ALB 오리진
- Route53 alias record와 CloudFront ACM 검증

## 타임아웃과 Keepalive 계획

인그레스 타임아웃은 사용자와 맞닿는 바깥 계층이 내부 서비스 제한보다 약간 길게 잡히도록 맞춘다. 이렇게 해야 사용자가 edge/proxy 연결 끊김 대신 애플리케이션 오류를 받을 수 있다.

| 경로 | 타임아웃 / keepalive | 이유 |
|---|---:|---|
| 브라우저 API 호출 | 기본 5초, AI 추천 요청 70초 | 일반 UX는 빠르게 실패시키고, AI 작업은 모델 처리 시간을 기다림 |
| CloudFront -> 프론트 ALB 오리진 | connect 10초, read 60초, keepalive 60초 | `doktori.kr` 사이트 오리진 한도이며 장기 API/SSE/WS 용도가 아님 |
| 공개 ALB idle timeout | 3600초 | 직접 ALB 도메인을 쓰는 WebSocket/SSE 연결 유지 |
| NGF `/api/` route | backendRequest 65초 | Spring의 고정 AI read timeout보다 약간 길게 설정 |
| Spring API/Chat -> AI service | connect 10초, read 60초 | 백엔드 코드에 고정되어 있으며 추가 SSM timeout parameter 없음 |
| AI -> RunPod | submit 8초, status 5초, poll 40초 | submit/status는 코드 상수, poll은 기존 RunPod poll timeout 설정 사용 |
| NGF `/api/chat-rooms` route | backendRequest 31분 | waiting-room SSE emitter 30분 + 30초 heartbeat |
| NGF `/ws/chat` route | backendRequest 1시간 | WebSocket 경로이며 ALB 3600초 idle timeout과 맞춤 |
| NGF upstream keepAlive | 연결 64개, 요청 1000회, max age 1시간, idle 60초 | pod upstream TCP 연결을 재사용하되 유휴 socket을 과도하게 유지하지 않음 |

실시간 트래픽은 `api.doktori.kr`를 사용해 WebSocket/SSE가 CloudFront를 우회하고 ALB + NGF 장기 연결 설정을 따르게 한다. `doktori.kr/api/*`를 CloudFront 경유로 쓰는 것은 일반/짧은 API 호출과 OAuth 콜백에는 가능하지만, 장기 SSE 스트림에는 적합하지 않다.

## `staging` 수명주기

`staging`은 상시 운영 환경이 아니다. `.github/workflows/terraform-staging.yml`로 수동 관리한다.

| 동작 | 설명 |
|------|------|
| `apply` | `staging/base`를 먼저 적용한 뒤 현재 워크플로우는 `staging/app`과 `staging/data`를 병렬 적용 |
| `start` | EC2와 RDS 시작 후 nginx 헬스 체크 실행 |
| `stop` | EC2와 RDS 정지 |
| `scale` | `staging/app`을 기본 사양과 `prod-spec.tfvars` 프로파일 사이에서 전환 |
| `deploy` | `api`, `chat` 서비스 배포 |
| `destroy` | `data`, `app`, `base` 순서로 삭제하며 data destroy 전에 RDS를 state에서 제거 |

[CICD.md](./CICD.md)는 의존성 안전성을 위해 `data`를 `app`보다 먼저 적용하는 순서를 권장한다. 현재 staging 워크플로우는 `base` 이후 `app`과 `data`를 같은 매트릭스에서 병렬 실행하므로, 새로운 app -> data 원격 state 의존성을 추가할 때 주의한다.

## 모듈

### networking

VPC, 서브넷, 라우트 테이블, NAT 인스턴스, S3 Gateway Endpoint, 선택 Interface Endpoint, Route53 프라이빗 호스팅 영역을 만든다.

- `subnets` map으로 서브넷 생성
- `nat_instances` map으로 multi-AZ NAT 인스턴스 생성 가능
- 프라이빗 라우트 테이블은 NAT key별 생성
- S3 Gateway Endpoint는 기본 생성
- Interface Endpoint는 `vpc_interface_endpoints` list로 선택

### compute

EC2, Security Group, IAM Role/Profile, IAM policy, 선택 EIP를 만든다.

- `services` map으로 N개 인스턴스 선언
- `sg_cross_rules`로 SG 간 참조 규칙 분리
- 서비스별 AMI, architecture, volume, user_data 재정의 가능
- `associate_eip` flag로 EIP 조건부 할당
- IMDSv2 강제, EBS 암호화 기본 적용
- `enable_batch_self_stop`로 태그가 붙은 batch 인스턴스의 self-stop 권한 부여 가능

### frontend

공개 ALB와 프론트 Auto Scaling Group을 만든다.

- ALB idle timeout 기본값은 3600초
- 프론트 ASG는 프라이빗 서브넷에 배치
- app layer에서 경로 기반 rule을 추가할 수 있도록 HTTP listener ARN을 출력값으로 제공
- CodeDeploy 연동에 필요한 ASG/TG/LT 출력값 제공

### k8s-cluster

Kubernetes control-plane/worker Auto Scaling Group과 내부 NLB를 만든다.

- master ASG는 desired/min/max를 동일하게 유지
- worker ASG는 desired/min/max를 별도로 설정
- 내부 NLB는 control-plane endpoint로 사용
- worker ASG target group attachment는 prod app layer에서 ALB backend TG와 연결

### database

RDS MySQL, DB 서브넷 그룹, 파라미터 그룹, password SSM, 선택 RDS Proxy를 만든다.

- DB password는 `random_password`로 생성 후 SSM SecureString에 저장
- RDS instance password와 RDS Proxy secret은 SSM 값을 ephemeral로 읽어 `*_wo` 속성에 주입
- `db_extra_parameters`로 환경별 파라미터 그룹 추가 설정
- `enable_rds_proxy`로 RDS Proxy/Secrets Manager 리소스 생성
- RDS instance에는 `prevent_destroy` lifecycle이 있다

### storage

S3, 버전 관리, CORS, 암호화, 공개 읽기 prefix policy, 선택 KMS/IAM/ECR을 만든다.

- `s3_buckets` map으로 버킷별 설정
- `folders`로 prefix 자리표시자 object 생성
- 환경 `data` 레이어에서는 주로 S3 버킷 용도로 사용
- ECR은 현재 `terraform/ecr` 루트 모듈에서 공용 관리

### ssm-parameters

SSM Parameter Store 껍데기 리소스를 만든다.

- 앱 설정값의 이름과 타입을 Terraform으로 선생성
- 기본값은 `CHANGE_ME`
- `ignore_changes = [value, description]`으로 CLI/운영 주입 값을 덮어쓰지 않음
- Terraform이 계산 가능한 값은 환경 `base`/`data` 레이어에서 별도 `aws_ssm_parameter`로 직접 쓴다

## 전역 리소스

`terraform/global/`은 계정 수준 리소스를 관리한다.

- GitHub OIDC provider
- GitHub Actions deploy role
- GitHub Actions Terraform role
- IAM group: cloud, be, fe, ai
- IAM user와 그룹 membership
- 팀별 SSM 접근 policy
- SSM, Auto Scaling service-linked role
- 월간 예산 알림

## CI/CD

상세 설계와 차이 분석은 [CICD.md](./CICD.md)를 기준으로 한다.

현재 워크플로우:

| 워크플로우 | 트리거 | 역할 |
|------------|--------|------|
| `.github/workflows/terraform.yml` | PR, main push, schedule | fmt, validate, tfsec, plan comment, Infracost, drift, 순서형 apply 작업 |
| `.github/workflows/terraform-staging.yml` | workflow_dispatch | staging apply/start/stop/scale/deploy/destroy |

현재 `terraform.yml`의 `APPLY_DISABLED`가 `"true"`라 main push 자동 apply 작업은 실행되지 않는다. PR 검증과 schedule drift는 계속 사용한다.

PR 워크플로우:

- `terraform fmt -check -recursive terraform/`
- 변경된 루트 모듈 `init -backend=false` + `validate`
- `tfsec`는 경고로 처리
- 변경된 루트 모듈 plan
- destroy 문자열 감지와 PR comment
- Infracost diff comment

Apply 워크플로우가 다시 활성화될 때의 순서:

```
global -> ecr -> dns_zone -> monitoring/base -> monitoring/data -> monitoring/app
-> env/base -> env/data -> env/app -> prod/cdn
```

자동 apply는 plan JSON에서 delete action을 감지하면 실패하도록 되어 있다. `prod`/shared는 GitHub Environment 승인을 사용한다.

## 보안

### IAM

- GitHub OIDC token 기반 인증
- Deploy role과 Terraform role 분리
- 팀별 SSM Session Manager 및 Parameter Store 접근 제어
- EC2 role은 필요한 S3/SSM/ECR/CloudWatch 범위로 제한

### 네트워크

- prod/staging 서비스 노드는 대부분 프라이빗 서브넷에 배치
- prod 공개 ALB만 인터넷 인입을 받음
- SG cross-rule은 출발지 SG 또는 제한된 CIDR 기반으로 관리
- IMDSv2 강제
- EBS/S3 암호화 기본 적용

### 시크릿

- DB password는 SSM SecureString에 저장
- RDS password, RDS Proxy secret, DB URL/Mongo URI는 가능한 `*_wo`와 ephemeral read를 사용
- 앱 시크릿 껍데기는 SSM Parameter Store에 만들고 실제 값은 CLI/운영 절차로 주입
- `.tfvars`는 gitignore 대상

## 운영 메모

### Destroy 시 주의

- prod RDS와 CodeDeploy revision 버킷은 보호 리소스다.
- database 모듈의 RDS에는 `prevent_destroy`가 있으므로 삭제하려면 state 조작과 별도 수동 절차가 필요하다.
- staging destroy 워크플로우는 RDS를 먼저 state에서 제거한 뒤 destroy한다.
- 자동 apply는 delete action을 차단한다.

### 모듈 변경 영향

`modules/` 변경은 해당 모듈을 참조하는 모든 루트 모듈의 plan 대상이 된다. 특히 `networking`, `compute`, `storage`, `database`는 여러 환경에 재사용되므로 변경 전 영향 범위를 확인한다.

### Drift 방지

- 모든 리소스에 `ManagedBy=Terraform` 기본 tag를 부여한다.
- AWS Console 수동 변경은 다음 apply에서 덮어써질 수 있다.
- `terraform state mv/rm`은 팀 공유 후 실행한다.
- apply 후 `scripts/assert-clean-plan.sh`로 clean plan을 확인한다.

### 이름 규칙

```
{project}-{environment}-{resource}
```

예: `doktori-prod-vpc`, `doktori-staging-nginx-sg`, `doktori-dev-ec2-ssm`

## 알려진 제한 사항

- `prod/data`의 Redis/RabbitMQ HA는 `enable_data_ha = false`가 기본이라 현재 첫 apply 기준은 단일 노드다.
- RDS는 prod에서도 단일 AZ 인스턴스이며 Multi-AZ RDS가 아니다.
- prod Interface VPC Endpoint는 비용 절감을 위해 비활성화되어 있고 NAT 인스턴스 경유를 사용한다.
- DB password 초기 생성 경로는 `random_password`와 SSM parameter value를 사용하므로 일부 민감값이 Terraform state에 남을 수 있다.
- Terraform IAM role은 일부 EC2/RDS/S3 권한에서 넓은 리소스 범위를 사용한다.
- staging은 mgmt VPC peering이 없어 monitoring 접근은 VPN 또는 별도 경로가 필요하다.
- `prod/loadtest` 루트 모듈은 존재하지만 현재 `terraform.yml` 감지/drift 매트릭스에는 포함되어 있지 않다.
