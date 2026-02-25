# Instance setup guide

Last updated: 2026-02-18
Author: jbdev

인스턴스 생성 후 user_data 자동화 항목과 수동 작업을 인스턴스별로 정리한 절차서.

## Before you begin

- AWS CLI 설정 완료 (`aws sts get-caller-identity`로 확인)
- Terraform으로 인프라 프로비저닝 완료 (VPC, 서브넷, SG)
- SSH 키 또는 SSM 접근 권한 확보

## Instance overview

| 인스턴스 | 모듈 | 서브넷 | OS | 아키텍처 | 용도 |
|----------|------|--------|-----|---------|------|
| NAT Instance | `nonprod/networking` | public | Ubuntu 24.04 | ARM (t4g.nano) | private 서브넷 아웃바운드 |
| Dev App | `nonprod/compute` | private-app | Ubuntu 22.04 | x86 (t3.small) | Docker Compose 올인원 |
| Monitoring | `monitoring` | Default VPC | Ubuntu 24.04 | ARM (t4g.small) | Prometheus+Loki+Grafana |

## Set up NAT Instance

### user_data 자동 설치

- [x] IP forwarding (`net.ipv4.ip_forward = 1`)
- [x] iptables MASQUERADE (VPC CIDR → 외부 NAT)
- [x] iptables-persistent (재부팅 후 유지)

### Terraform 자동 설정

- [x] `source_dest_check = false`
- [x] EIP 할당

### 수동 작업: 없음

## Set up Dev App EC2

### user_data 자동 설치

- [x] Docker CE + Docker Compose plugin
- [x] AWS CLI v2 (x86_64)
- [x] SSM Agent
- [x] 기본 도구 (htop, vim, jq, net-tools, tree)
- [x] Swap 2GB
- [x] Timezone Asia/Seoul
- [x] `~/app` 디렉토리 생성

### Terraform 자동 설정

- [x] IAM Instance Profile (SSM + S3 + Parameter Store + ECR pull)
- [x] Security Group (VPC 내부 통신만)

### 수동 작업

1. Configure ECR credential helper

   ```bash
   aws ssm start-session --target <DEV_INSTANCE_ID>

   sudo apt-get install -y amazon-ecr-credential-helper
   mkdir -p ~/.docker
   echo '{"credsStore": "ecr-login"}' > ~/.docker/config.json
   ```

2. Deploy docker-compose.dev.yml

   ```bash
   # 로컬에서 SCP 또는 S3 경유
   # Cloud/docker-compose.dev.yml → ~/app/docker-compose.dev.yml
   # Cloud/nginx/ → ~/app/nginx/

   cd ~/app
   docker compose -f docker-compose.dev.yml pull
   docker compose -f docker-compose.dev.yml up -d
   ```

3. Create .env from Parameter Store

   ```bash
   aws ssm get-parameters-by-path \
     --path "/doktori/nonprod/" \
     --with-decryption \
     --query "Parameters[*].[Name,Value]" \
     --output text
   # → ~/app/.env 로 저장
   ```

4. Configure Alloy agent

   ```bash
   mkdir -p ~/app/alloy
   # config.alloy 복사 (SCP 또는 S3 경유)
   # Cloud/monitoring/alloy/config.alloy → ~/app/alloy/config.alloy

   # .env에 모니터링 IP 추가 (config.alloy가 env()로 읽음, sed 불필요)
   echo "MONITORING_IP=<MONITORING_EIP>" >> ~/app/.env

   docker compose -f docker-compose.dev.yml up -d
   ```

## Set up Monitoring EC2

### user_data 자동 설치

- [x] Docker CE + Docker Compose plugin
- [x] AWS CLI v2 (아키텍처별 자동 분기: arm64/x86_64)
- [x] SSM Agent
- [x] 기본 도구 (htop, vim, jq, net-tools, tree)
- [x] Swap 2GB
- [x] Timezone Asia/Seoul
- [x] `/home/ubuntu/monitoring` 디렉토리 생성

### Terraform 자동 설정

- [x] IAM Instance Profile (SSM)
- [x] Security Group (admin CIDR + target server CIDR)
- [x] EIP 할당

### 수동 작업

1. Transfer monitoring stack files

   ```bash
   scp -i ~/.ssh/doktori-monitoring.pem -r \
     Cloud/monitoring/{docker-compose.yml,prometheus,loki,grafana,.env.example} \
     ubuntu@<MONITORING_EIP>:~/monitoring/
   ```

2. Configure .env

   ```bash
   ssh -i ~/.ssh/doktori-monitoring.pem ubuntu@<MONITORING_EIP>
   cd ~/monitoring
   cp .env.example .env
   vi .env  # GF_ADMIN_PASSWORD 설정
   ```

3. Start monitoring stack

   ```bash
   cd ~/monitoring
   docker compose up -d
   ```

4. Install WireGuard VPN (선택, Grafana 접근 제한용)

   ```bash
   sudo apt install -y wireguard
   # wg0.conf 설정 → 별도 VPN 문서 참조
   ```

## Prod instances (향후)

| 인스턴스 | 서브넷 | 용도 | user_data |
|----------|--------|------|-----------|
| NAT Instance | public | private 아웃바운드 | IP forwarding + iptables |
| Nginx | public | 리버스 프록시 + SSL | Docker + nginx 설정 |
| API | private-app | Backend API 서버 | Docker + ECR |
| Chat | private-app | Chat 서버 (WebSocket) | Docker + ECR |
| AI | private-app | AI 추론 서버 | Docker + ECR |
| Frontend | private-app | Next.js SSR | Docker + ECR |
| DB (MySQL) | private-db | MySQL 8.0 | MySQL + 백업 설정 |

> Monitoring은 전체 환경(dev/staging/prod)을 관측하므로 별도 VPC(Default VPC)에 1대만 운영.

## Bootstrap deploy order

```
1. S3 Backend         terraform/backend/             → state 저장소
2. Nonprod Networking terraform/nonprod/networking/   → VPC, 서브넷, NAT
3. Monitoring         terraform/monitoring/           → Default VPC에 독립 배치
4. Nonprod Compute    terraform/nonprod/compute/      → Dev App EC2
5. Nonprod Storage    terraform/nonprod/storage/      → S3 버킷
6. Nonprod DNS        terraform/nonprod/dns/          → Route53
7. IAM                terraform/iam/                  → GitHub Actions OIDC
8. Parameter Store    terraform/parameter-store/      → 시크릿 관리
```

각 단계에서:

```bash
cd terraform/<module>/
terraform init -backend-config=../../backend.hcl
terraform plan
terraform apply
```

## Verify

```bash
# NAT Instance
aws ssm start-session --target <DEV_INSTANCE_ID>
curl -s ifconfig.me  # NAT EIP가 출력되면 성공

# Dev App
docker compose -f docker-compose.dev.yml ps  # 전 컨테이너 Up
curl -s localhost:8080/api/health              # Backend API
curl -s localhost:3000                         # Frontend
docker logs alloy --tail 20                    # Alloy 로그 push 확인

# Monitoring
docker compose ps
curl -s localhost:9090/-/healthy                # Prometheus
curl -s localhost:3100/ready                    # Loki
curl -s localhost:3000/api/health               # Grafana
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `curl ifconfig.me` 실패 (dev 서버) | NAT Instance 라우팅 미설정 | private route table 에 NAT ENI 라우트 확인 |
| ECR pull 실패 | credential helper 미설치 | `~/.docker/config.json` 에 `ecr-login` 설정 |
| Alloy push 실패 | Monitoring SG에 NAT EIP 미등록 | `target_server_cidrs`에 NAT EIP 추가 |

## What's next

- [Alloy push monitoring deploy](../deployment/monitoring-deploy.md)
- [AWS account switch guide](../operations/account-switch.md)