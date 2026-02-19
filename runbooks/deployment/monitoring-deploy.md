# Alloy push monitoring deploy

Last updated: 2026-02-18
Author: jbdev

Alloy 기반 Push 모니터링 스택을 NAT Instance → Monitoring 서버 경로로 배포하는 절차서.

## Before you begin

- Terraform CLI 설치 완료
- AWS CLI 프로필이 올바른 계정을 가리키는지 확인 (`aws sts get-caller-identity`)
- SSH 키 `~/.ssh/doktori-monitoring.pem` 준비
- Dev VPC 네트워킹 모듈 프로비저닝 완료 (`terraform/nonprod/networking/`)

## Architecture

```
Dev VPC (10.0.0.0/16)
┌─────────────────────────────────────────────────────┐
│ Public Subnet                                       │
│ ┌─────────────────┐                                 │
│ │ NAT Instance    │ t4g.nano, $3/월                 │
│ │ (EIP attached)  │ source_dest_check=false          │
│ │ iptables MASQ   │ IP forwarding + MASQUERADE       │
│ └────────▲────────┘                                 │
│          │                                           │
│ Private Subnet (route 0.0.0.0/0 → NAT ENI)         │
│ ┌────────┴────────────────────┐                     │
│ │ Dev EC2 (Docker Compose)    │                     │
│ │                              │                     │
│ │ alloy ──── push (outbound) ─┼──→ NAT ──→ Internet │
│ │   ├ unix (host metrics)     │         │            │
│ │   ├ mysql (내장 exporter)    │         ▼            │
│ │   ├ actuator (Docker 내부)   │  Monitoring EC2      │
│ │   ├ nginx-exporter:9113     │  ┌────────────────┐  │
│ │   └ docker logs             │  │ prometheus:9090 │  │
│ │                              │  │ loki:3100       │  │
│ │ nginx-exporter              │  │ grafana:3000    │  │
│ │   └ nginx:8888/stub         │  │ blackbox:9115   │  │
│ └──────────────────────────────┘  └────────────────┘  │
│   인바운드 포트 0개                  SG: NAT EIP만     │
└─────────────────────────────────────────────────────┘
```

## Step 0: Provision NAT Instance (Terraform)

1. Apply the networking module

   ```bash
   cd Cloud/terraform/nonprod/networking/
   terraform init
   terraform plan
   terraform apply
   ```

2. Note the NAT EIP for later steps

   ```bash
   terraform output nat_public_ip
   ```

   > **Note:** 이 IP를 Step 1의 `target_server_cidrs`에 사용한다.

## Step 1: Provision monitoring server (Terraform)

1. Create terraform.tfvars

   ```bash
   cd Cloud/terraform/monitoring/
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Edit terraform.tfvars

   ```hcl
   project_name = "doktori"
   aws_region   = "ap-northeast-2"

   architecture     = "arm64"
   instance_type    = "t4g.medium"
   key_name         = "doktori-monitoring"
   root_volume_size = 30

   allowed_admin_cidrs = [
     "YOUR_IP/32",
   ]

   target_server_cidrs = [
     "NAT_INSTANCE_EIP/32",  # terraform output nat_public_ip 값
   ]
   ```

3. Apply

   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

4. Note the monitoring EIP

   ```bash
   terraform output monitoring_eip
   ```

## Step 2: Set up monitoring server

1. Connect and install Docker

   ```bash
   ssh -i ~/.ssh/doktori-monitoring.pem ubuntu@$(terraform output -raw monitoring_eip)

   sudo apt update && sudo apt install -y docker.io docker-compose-v2
   sudo usermod -aG docker ubuntu
   exit
   ```

2. Reconnect and deploy the stack

   ```bash
   ssh -i ~/.ssh/doktori-monitoring.pem ubuntu@<MONITORING_EIP>
   mkdir -p ~/monitoring && cd ~/monitoring
   ```

3. Transfer files from local

   ```bash
   scp -i ~/.ssh/doktori-monitoring.pem -r \
     Cloud/monitoring/{docker-compose.yml,prometheus,loki,grafana,.env.example} \
     ubuntu@<MONITORING_EIP>:~/monitoring/
   ```

4. Configure and start

   ```bash
   cd ~/monitoring
   cp .env.example .env
   vi .env  # GF_ADMIN_PASSWORD 설정
   docker compose up -d
   ```

## Step 3: Update Dev server SG (Terraform)

1. Apply compute module changes

   ```bash
   cd Cloud/terraform/nonprod/compute/
   terraform plan    # exporter 포트 4개 제거 확인 (9100/9104/9113/9080)
   terraform apply
   ```

   > **Note:** plan 결과에서 ingress rule 4개 삭제, 나머지 변경 없음을 확인한다.

## Step 4: Deploy Alloy on Dev server

1. Connect via SSM and configure Alloy

   ```bash
   aws ssm start-session --target <DEV_INSTANCE_ID>

   sudo -u ubuntu mkdir -p ~/app/alloy
   ```

2. `.env`에 모니터링 IP 추가

   ```bash
   # ~/app/.env
   echo "MONITORING_IP=<MONITORING_EIP>" >> ~/app/.env
   ```

   > `config.alloy`는 `env("MONITORING_IP")`, `env("ALLOY_ENV")`를 사용하므로 sed 치환 불필요.
   > `ALLOY_ENV`는 docker-compose.dev.yml에 `dev`로 하드코딩되어 있음.

3. Restart compose stack

   ```bash
   cd ~/app
   docker compose -f docker-compose.dev.yml up -d
   ```

## Step 5: Clean up legacy exporters

Alloy 연결 확인 완료 후 기존 개별 exporter를 제거한다.

```bash
# systemd 기반
sudo systemctl stop node_exporter mysqld_exporter nginx-exporter promtail 2>/dev/null
sudo systemctl disable node_exporter mysqld_exporter nginx-exporter promtail 2>/dev/null

# Docker 기반
docker stop node_exporter mysqld_exporter nginx-exporter promtail 2>/dev/null
docker rm node_exporter mysqld_exporter nginx-exporter promtail 2>/dev/null

# 바이너리 삭제
sudo rm -f /usr/local/bin/{node_exporter,mysqld_exporter,nginx-prometheus-exporter,promtail}
```

## Verify

### Alloy → Prometheus 메트릭 수신

```bash
curl -s 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result[] | {instance: .metric.instance, job: .metric.job, env: .metric.env}'
```

기대 결과: `env: "dev"` 라벨이 달린 메트릭이 보여야 함

### Alloy → Loki 로그 수신

```bash
curl -s 'http://localhost:3100/loki/api/v1/query?query={env="dev"}' | jq '.data.result | length'
```

기대 결과: 0보다 큰 숫자

### Grafana 대시보드

- 브라우저: `http://<MONITORING_EIP>:3000`
- admin / (설정한 비밀번호)
- Explore → Prometheus 데이터소스 → `up{env="dev"}` 쿼리

### Blackbox 프로빙

```bash
curl -s 'http://localhost:9090/api/v1/query?query=probe_success' | jq '.data.result[]'
```

## Rollback

```bash
# dev 서버: alloy + nginx-exporter 중지
docker compose -f docker-compose.dev.yml stop alloy nginx-exporter

# 기존 exporter 다시 시작 (제거하기 전이라면)
sudo systemctl start node_exporter mysqld_exporter nginx-exporter promtail
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Alloy push 실패 | Monitoring SG에 NAT EIP 미등록 | `target_server_cidrs`에 NAT EIP/32 추가 |
| `curl ifconfig.me` 실패 (dev) | NAT Instance 라우팅 미설정 | private route table 확인 |
| Grafana 접속 불가 | admin CIDR 미등록 | `allowed_admin_cidrs` 업데이트 |
| 메트릭에 `env` 라벨 없음 | `ALLOY_ENV` 환경변수 누락 | docker-compose.dev.yml의 alloy environment 확인 |

## What's next

- [Instance setup guide](../compute/instance-setup.md)
- [AWS account switch guide](../operations/account-switch.md)