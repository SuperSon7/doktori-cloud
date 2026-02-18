# Instance Setup Guide

인스턴스 생성 후 필요한 작업을 인스턴스별로 정리.
`user_data`로 자동화된 항목과 수동 작업을 구분.

---

## 인스턴스 목록

| 인스턴스 | 모듈 | 서브넷 | OS | 아키텍처 | 용도 |
|----------|------|--------|-----|---------|------|
| NAT Instance | `nonprod/networking` | public | Ubuntu 24.04 | ARM (t4g.nano) | private 서브넷 아웃바운드 |
| Dev App | `nonprod/compute` | private-app | Ubuntu 22.04 | x86 (t3.small) | Docker Compose 올인원 |
| Monitoring | `monitoring` | Default VPC | Ubuntu 24.04 | ARM (t4g.small) | Prometheus+Loki+Grafana |

---

## 1. NAT Instance

### user_data 자동 설치
- [x] IP forwarding (`net.ipv4.ip_forward = 1`)
- [x] iptables MASQUERADE (VPC CIDR → 외부 NAT)
- [x] iptables-persistent (재부팅 후 유지)

### Terraform 자동 설정
- [x] `source_dest_check = false`
- [x] EIP 할당

### 수동 작업: 없음

### 확인
```bash
# dev 서버(SSM)에서 외부 통신 테스트
aws ssm start-session --target <DEV_INSTANCE_ID>
curl -s ifconfig.me  # NAT EIP가 출력되면 성공
```

---

## 2. Dev App EC2

### user_data 자동 설치
- [x] Docker CE + Docker Compose plugin
- [x] AWS CLI v2 (x86_64)
- [x] SSM Agent
- [x] 기본 도구 (htop, vim, jq, net-tools, tree)
- [x] Swap 2GB
- [x] Timezone Asia/Seoul
- [x] `/opt/app` 디렉토리 생성

### Terraform 자동 설정
- [x] IAM Instance Profile (SSM + S3 + Parameter Store + ECR pull)
- [x] Security Group (VPC 내부 통신만)

### 수동 작업

#### A. ECR 로그인 설정
```bash
# SSM 접속
aws ssm start-session --target <DEV_INSTANCE_ID>

# ECR credential helper 설치
sudo apt-get install -y amazon-ecr-credential-helper
mkdir -p ~/.docker
echo '{"credsStore": "ecr-login"}' > ~/.docker/config.json
```

#### B. docker-compose.dev.yml 배포
```bash
# 로컬에서 SCP 또는 S3 경유
# Cloud/docker-compose.dev.yml → /opt/app/docker-compose.dev.yml
# Cloud/nginx/ → /opt/app/nginx/

cd /opt/app
docker compose -f docker-compose.dev.yml pull
docker compose -f docker-compose.dev.yml up -d
```

#### C. .env 파일 (Parameter Store에서)
```bash
# IAM 권한으로 Parameter Store에서 가져오기
aws ssm get-parameters-by-path \
  --path "/doktori/nonprod/" \
  --with-decryption \
  --query "Parameters[*].[Name,Value]" \
  --output text
# → /opt/app/.env 로 저장
```

#### D. Alloy 설정 (모니터링 에이전트)
```bash
mkdir -p /opt/app/alloy

# config.alloy 복사 후 플레이스홀더 치환
sed -i 's/__MONITORING_IP__/<MONITORING_EIP>/g; s/__ENV__/dev/g' \
  /opt/app/alloy/config.alloy

# docker-compose 재기동 (alloy 포함)
docker compose -f docker-compose.dev.yml up -d
```

### 확인
```bash
docker compose -f docker-compose.dev.yml ps  # 전 컨테이너 Up
curl -s localhost:8080/api/health              # Backend API
curl -s localhost:3000                         # Frontend
docker logs alloy --tail 20                    # Alloy 로그 push 확인
```

---

## 3. Monitoring EC2

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

#### A. 모니터링 스택 파일 전송
```bash
# 로컬에서 SCP
scp -i ~/.ssh/doktori-monitoring.pem -r \
  Cloud/monitoring/{docker-compose.yml,prometheus,loki,grafana,.env.example} \
  ubuntu@<MONITORING_EIP>:~/monitoring/
```

#### B. .env 설정
```bash
ssh -i ~/.ssh/doktori-monitoring.pem ubuntu@<MONITORING_EIP>
cd ~/monitoring
cp .env.example .env
vi .env  # GF_ADMIN_PASSWORD 설정
```

#### C. 모니터링 스택 기동
```bash
cd ~/monitoring
docker compose up -d
```

#### D. WireGuard VPN (선택, Grafana 접근 제한용)
```bash
sudo apt install -y wireguard
# wg0.conf 설정 → 별도 VPN 문서 참조
```

### 확인
```bash
docker compose ps                              # 전 컨테이너 Up
curl -s localhost:9090/-/healthy                # Prometheus
curl -s localhost:3100/ready                    # Loki
curl -s localhost:3000/api/health               # Grafana
# 브라우저: http://<MONITORING_EIP>:3000 → admin 로그인
```

---

## Prod 인스턴스 (staging 포함, 향후)

Prod VPC(10.1.0.0/16)에 생성될 인스턴스. nonprod와 동일 구조.

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

---

## 배포 순서 (전체 부트스트랩)

```
1. S3 Backend         terraform/backend/         → state 저장소
2. Nonprod Networking terraform/nonprod/networking/ → VPC, 서브넷, NAT
3. Monitoring         terraform/monitoring/       → Default VPC에 독립 배치
4. Nonprod Compute    terraform/nonprod/compute/   → Dev App EC2
5. Nonprod Storage    terraform/nonprod/storage/   → S3 버킷
6. Nonprod DNS        terraform/nonprod/dns/       → Route53
7. IAM                terraform/iam/              → GitHub Actions OIDC
8. Parameter Store    terraform/parameter-store/  → 시크릿 관리
```

각 단계에서:
```bash
cd terraform/<module>/
terraform init -backend-config=../../backend.hcl  # shared 모듈은 ../backend.hcl
terraform plan
terraform apply
```

---

## ChatOps 연동 포인트

향후 ChatOps(Discord/Slack) 도입 시, 아래 명령을 봇이 실행할 수 있도록 구성:

| 명령 | 동작 | 대상 |
|------|------|------|
| `/deploy dev` | ECR pull + docker compose up | Dev App EC2 (SSM) |
| `/deploy monitoring` | docker compose pull + up | Monitoring EC2 (SSM) |
| `/status dev` | docker compose ps + health check | Dev App EC2 |
| `/status monitoring` | docker compose ps + health check | Monitoring EC2 |
| `/logs dev <service>` | docker logs --tail 50 | Dev App EC2 |
| `/restart dev <service>` | docker compose restart <service> | Dev App EC2 |
| `/scale staging <service> <n>` | docker compose up --scale | Staging (향후) |

모든 명령은 **SSM SendCommand**로 실행 → SSH 키 없이, IAM 권한만으로 동작.
