# Alloy Push 모니터링 배포 런북

## 아키텍처 요약

```
Dev EC2 (Private Subnet)                    Monitoring EC2 (Public Subnet)
┌──────────────────────────┐                ┌──────────────────────────────┐
│ Docker Compose (app-net) │                │ Docker Compose (monitoring)  │
│                          │                │                              │
│ alloy ───────────────────┼── push ──────→ │ prometheus :9090             │
│   ├ unix (host metrics)  │  remote_write  │   (--web.enable-remote-     │
│   ├ mysql (내장 exporter) │                │    write-receiver)           │
│   ├ actuator (직접 접근)  │                │                              │
│   ├ nginx-exporter:9113  ├── push ──────→ │ loki :3100                   │
│   └ docker logs          │  loki push     │                              │
│                          │                │ grafana :3000                │
│ nginx-exporter           │                │ blackbox-exporter :9115      │
│   └ nginx:8888/stub      │                │   └ probe → dev.doktori.kr  │
└──────────────────────────┘                └──────────────────────────────┘
     인바운드 포트 0개                            SG: target_server_cidrs
     (아웃바운드 push만)                                → 9090, 3100
```

---

## Step 1: 모니터링 서버 프로비저닝 (Terraform)

```bash
cd Cloud/terraform/monitoring/

# terraform.tfvars 생성 (example 참고)
cp terraform.tfvars.example terraform.tfvars
```

**terraform.tfvars 작성:**
```hcl
project_name = "doktori"
aws_region   = "ap-northeast-2"

architecture     = "arm64"
instance_type    = "t4g.medium"
key_name         = "doktori-monitoring"
root_volume_size = 30

# 관리자 IP (본인 IP 확인: curl ifconfig.me)
allowed_admin_cidrs = [
  "YOUR_IP/32",       # 본인 IP
]

# dev 서버 퍼블릭 IP (NAT Gateway 또는 EIP)
# dev 서버가 private subnet → NAT GW 통해 나가므로 NAT GW의 EIP 필요
target_server_cidrs = [
  "DEV_NAT_GW_EIP/32",  # dev 서버 아웃바운드 IP
]
```

> **중요**: dev 서버는 private subnet에 있어 아웃바운드 트래픽이 NAT Gateway를 통해 나감.
> `target_server_cidrs`에는 NAT Gateway의 EIP를 넣어야 함.
> 확인: AWS 콘솔 → VPC → NAT Gateways → Elastic IP 확인
> 또는: `aws ec2 describe-nat-gateways --query 'NatGateways[].NatGatewayAddresses[].PublicIp'`

```bash
terraform init
terraform plan    # 리소스 확인
terraform apply   # 프로비저닝
```

**출력값 메모:**
```bash
terraform output monitoring_eip  # → 모니터링 서버 EIP (config.alloy에 사용)
```

---

## Step 2: 모니터링 서버 초기 세팅

```bash
# SSH 접속 (EIP 사용)
ssh -i ~/.ssh/doktori-monitoring.pem ubuntu@$(terraform output -raw monitoring_eip)

# Docker + Docker Compose 설치
sudo apt update && sudo apt install -y docker.io docker-compose-v2
sudo usermod -aG docker ubuntu
# 재접속 (docker 그룹 적용)
exit && ssh -i ~/.ssh/doktori-monitoring.pem ubuntu@<MONITORING_EIP>

# 모니터링 스택 배포
mkdir -p ~/monitoring && cd ~/monitoring

# 로컬에서 파일 전송 (scp)
# Cloud/monitoring/ 디렉터리 전체를 전송
scp -i ~/.ssh/doktori-monitoring.pem -r \
  Cloud/monitoring/{docker-compose.yml,prometheus,loki,grafana,.env.example} \
  ubuntu@<MONITORING_EIP>:~/monitoring/

# .env 설정
cp .env.example .env
vi .env  # GF_ADMIN_PASSWORD 설정

# 기동
docker compose up -d

# 확인
docker compose ps
curl -s localhost:9090/-/healthy  # Prometheus
curl -s localhost:3100/ready      # Loki
curl -s localhost:3000/api/health # Grafana
```

---

## Step 3: Dev 서버 SG 업데이트 (Terraform)

```bash
cd Cloud/terraform/dev/compute/

terraform plan    # exporter 포트 4개 제거 확인 (9100/9104/9113/9080)
terraform apply
```

**확인 포인트**: plan 결과에서 ingress rule 4개 삭제, 나머지 변경 없음

---

## Step 4: Dev 서버에 Alloy 배포

```bash
# SSM으로 dev 서버 접속
aws ssm start-session --target <DEV_INSTANCE_ID>

# Alloy config 디렉터리 생성
sudo -u ubuntu mkdir -p /opt/app/alloy

# config.alloy 생성 (플레이스홀더 치환)
# Cloud/monitoring/alloy/config.alloy 를 복사 후 sed로 치환
sudo -u ubuntu cat > /opt/app/alloy/config.alloy << 'HEREDOC'
<config.alloy 내용 붙여넣기>
HEREDOC

# 플레이스홀더 치환
sed -i 's/__MONITORING_IP__/<MONITORING_EIP>/g; s/__ENV__/dev/g' \
  /opt/app/alloy/config.alloy

# docker-compose.dev.yml 업데이트 (alloy + nginx-exporter 추가된 버전)
# 기존 docker-compose.dev.yml 을 교체

# nginx.conf 업데이트 (stub_status 추가된 버전)
# 기존 nginx.conf 를 교체

# compose 재기동
cd /opt/app
docker compose -f docker-compose.dev.yml up -d

# 확인
docker compose -f docker-compose.dev.yml ps
docker logs <alloy-container> --tail 50
```

---

## Step 5: 연결 확인

### 5-1. Alloy → Prometheus 메트릭 수신 확인
```bash
# 모니터링 서버에서
curl -s 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result[] | {instance: .metric.instance, job: .metric.job, env: .metric.env}'
```

**기대 결과**: `env: "dev"` 라벨이 달린 메트릭이 보여야 함

### 5-2. Alloy → Loki 로그 수신 확인
```bash
curl -s 'http://localhost:3100/loki/api/v1/query?query={env="dev"}' | jq '.data.result | length'
```

**기대 결과**: 0보다 큰 숫자

### 5-3. Grafana 대시보드 확인
- 브라우저: `http://<MONITORING_EIP>:3000`
- admin / (설정한 비밀번호)
- Explore → Prometheus 데이터소스 → `up{env="dev"}` 쿼리

### 5-4. Blackbox 프로빙 확인
```bash
curl -s 'http://localhost:9090/api/v1/query?query=probe_success' | jq '.data.result[]'
```

---

## 기존 Exporter 정리 (dev 서버)

Alloy 연결 확인 완료 후, 기존 개별 exporter 제거:

```bash
# dev 서버에서 (SSM)
# 기존 exporter가 systemd로 돌고 있다면:
sudo systemctl stop node_exporter mysqld_exporter nginx-exporter promtail 2>/dev/null
sudo systemctl disable node_exporter mysqld_exporter nginx-exporter promtail 2>/dev/null

# 또는 Docker로 돌고 있다면:
docker stop node_exporter mysqld_exporter nginx-exporter promtail 2>/dev/null
docker rm node_exporter mysqld_exporter nginx-exporter promtail 2>/dev/null

# 바이너리 삭제
sudo rm -f /usr/local/bin/{node_exporter,mysqld_exporter,nginx-prometheus-exporter,promtail}
```

---

## 롤백

문제 발생 시:

```bash
# dev 서버: alloy + nginx-exporter 중지
docker compose -f docker-compose.dev.yml stop alloy nginx-exporter

# 기존 exporter 다시 시작 (제거하기 전이라면)
sudo systemctl start node_exporter mysqld_exporter nginx-exporter promtail
```

---

## 면접 설명 포인트

### "왜 Pull에서 Push로 전환했나요?"

> dev 서버가 **private subnet**에 있고, 모니터링 서버와 **VPC가 분리**(CIDR 10.0.0.0/16 겹침 → 피어링 불가)되어 있었습니다.
> Pull 방식이면 모니터링 서버가 dev 서버의 exporter 포트(9100/9104/9113/9080)에 접근해야 하는데,
> 이를 위해 **퍼블릭 경유**가 필요 → private subnet의 보안 의미가 퇴색됩니다.
> Push 방식(Alloy remote_write)으로 전환하면 dev 서버는 **인바운드 포트 0개**,
> 아웃바운드만으로 메트릭/로그를 전송하므로 공격 표면이 크게 줄어듭니다.

### "왜 Alloy를 선택했나요?"

> 1. **통합 에이전트**: node_exporter + mysqld_exporter + promtail 3개를 하나로 대체 → 운영 복잡도 감소
> 2. **Promtail EOL 대응**: Grafana가 공식 후속으로 권장하는 에이전트
> 3. **Docker Compose 친화**: 같은 Docker 네트워크에서 Spring Boot actuator에 직접 접근 → nginx ACL 우회 (기존 Pull에서 403 발생하던 문제 해결)
> 4. **확장성**: Phase 5에서 OpenTelemetry tracing 추가 시 config 블록만 추가하면 됨

### "nginx-exporter만 사이드카로 남긴 이유는?"

> Alloy에 nginx 내장 exporter가 없어서 stub_status → Prometheus 포맷 변환을 위해 유지합니다.
> 다만 8MB 이미지 + 32MB 메모리로 오버헤드가 거의 없고,
> Docker 내부 네트워크에서만 통신하므로 외부 노출은 없습니다.

### "단일 에이전트의 SPOF(단일 장애점) 문제는?"

> `restart: unless-stopped`으로 자동 재시작하고,
> 모니터링 서버의 **Blackbox Exporter**가 외부에서 dev 서버 health endpoint를 프로빙하므로
> Alloy가 죽어도 서비스 가용성 자체는 별도 경로로 감지됩니다.
> 또한 Phase 3에서 "메트릭 수신 중단 알림" (absent 함수)을 추가할 예정입니다.