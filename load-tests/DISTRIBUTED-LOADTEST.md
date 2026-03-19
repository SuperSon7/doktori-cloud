# 분산 부하테스트 운영 가이드

> 별도 AWS 계정(doktori-first)의 EC2 러너 3대에서 프로덕션(api.doktori.kr)에 부하를 생성한다.
> 결과는 Grafana 실시간 대시보드 + CLI 결과 조회로 확인한다.

## 인프라 구성

```
┌─ 부하 생성 계정 (246477585940) ──────────────────────┐
│                                                       │
│  러너 1 (13.124.202.148)  ← Grafana + Prometheus     │
│  러너 2 (15.165.59.190)                               │
│  러너 3 (43.201.14.184)                               │
│                                                       │
│  t4g.medium × 3 (2 vCPU, 4GB RAM)                    │
│  VPC: 10.200.0.0/16, public subnet                   │
│  접속: SSH (키: ~/.ssh/doktori-loadtest.pem)          │
└───────────────────────────────────────────────────────┘
         │ HTTPS (api.doktori.kr → ALB 직접, CF 우회)
         ▼
┌─ 프로덕션 계정 ──────────────────────────────────────┐
│  ALB → K8s NodePort 30080 → NGF                      │
│    /api/*   → api-svc (Pod × 2)                      │
│    /ws/*    → chat-svc (Pod × 2)                     │
└───────────────────────────────────────────────────────┘
```

## 접속 정보

| 서비스 | URL | 계정 |
|--------|-----|------|
| Grafana | http://13.124.202.148:3000 | admin / loadtest |
| Prometheus | http://13.124.202.148:9090 | - |
| SSH (러너 1) | `ssh -i ~/.ssh/doktori-loadtest.pem ubuntu@13.124.202.148` | |
| SSH (러너 2) | `ssh -i ~/.ssh/doktori-loadtest.pem ubuntu@15.165.59.190` | |
| SSH (러너 3) | `ssh -i ~/.ssh/doktori-loadtest.pem ubuntu@43.201.14.184` | |

## 부하테스트 실행

### 기본 실행

```bash
cd load-tests

# Grafana 연동 + 최신 코드 pull
./run-distributed.sh load --prom --pull

# Grafana 없이 (결과는 --result로 확인)
./run-distributed.sh load
```

| 옵션 | 설명 |
|------|------|
| `--prom` | Prometheus remote write 활성화 → Grafana에서 실시간 확인 |
| `--pull` | 실행 전 각 러너에서 `git pull` (코드 변경 후 첫 실행 시) |

### 시나리오 목록

#### 표준 부하 패턴

```bash
./run-distributed.sh smoke         # 기능 검증 (5 VU, 1분)
./run-distributed.sh load          # 일반 트래픽 (50→100 VU × 3대 = 300 VU, 16분)
./run-distributed.sh stress        # 한계 탐색 (100→500 VU × 3대 = 1500 VU, 13분)
./run-distributed.sh spike         # 급증 복구력 (100→500→100 VU, 5분)
./run-distributed.sh soak          # 장시간 안정성 (50 VU, 1시간)
```

#### 개별 시나리오

```bash
./run-distributed.sh guest-flow       # 비회원 탐색 (추천→목록→상세→검색)
./run-distributed.sh user-flow        # 로그인 사용자 (프로필→모임→알림)
./run-distributed.sh meeting-search   # 검색 병목 (중복 서브쿼리)
./run-distributed.sh chat-api         # 채팅 REST API (목록/생성/입장)
./run-distributed.sh chat-ws          # 채팅 WebSocket (STOMP 동시연결)
./run-distributed.sh notification     # 알림 SSE + API
./run-distributed.sh cache-test       # Nginx 캐시 HIT율
./run-distributed.sh image-upload     # S3 Presigned URL 업로드
./run-distributed.sh create-meeting   # 모임 생성 파이프라인
./run-distributed.sh join-meeting     # 동시 참여 레이스컨디션
```

#### 커스텀 시나리오

```bash
./run-distributed.sh custom k6/scenarios/my-meetings-n1.js
```

## 결과 확인

### 1. CLI 결과 조회 (3대 요약)

```bash
./run-distributed.sh --result
```

각 러너의 최신 k6 로그에서 핵심 지표를 추출하여 보여준다:
- `http_req_duration` (P90, P95)
- `http_req_failed` (에러율)
- `errors` (5xx)
- `http_reqs` (총 요청 수)
- `vus_max` (최대 VU)

### 2. Grafana 대시보드 (실시간)

`--prom` 옵션으로 실행하면 Grafana에서 실시간 확인 가능.

**Doktori Load Test 대시보드:** http://13.124.202.148:3000/d/doktori-k6-loadtest

| 패널 | 내용 |
|------|------|
| Active VUs | 현재 VU 수 추이 |
| Request Rate | 초당 요청 수 (req/s) |
| Response Time P50/90/95/99 | 응답시간 분포 |
| Error Rates | 5xx / 4xx / 전체 에러율 구분 |
| **Endpoint별 P95** | 어떤 API가 느린지 한눈에 |
| **Request Count by Endpoint** | 엔드포인트별 요청 수 분포 |
| **Failed by Status Code** | 401/404/500 등 에러 원인 구분 |
| HTTP Timing Breakdown | Blocked/TLS/Waiting(TTFB)/Receiving 분리 |
| Data Transfer | 송수신 바이트/초 |
| **SLO Compliance** | API 가용성 99.5% 달성 여부 (빨강/초록) |
| **P95 vs SLO** | P95 ≤ 1초 달성 여부 (빨강/초록) |
| **Check Pass Rate** | k6 check 통과율 |

**k6 Prometheus (공식):** http://13.124.202.148:3000 → Dashboards → k6 Prometheus (Native Histograms)

### 3. 러너 로그 직접 확인

```bash
# SSH로 직접 접속
ssh -i ~/.ssh/doktori-loadtest.pem ubuntu@13.124.202.148
cat /tmp/k6-*.log | tail -30

# 또는 원격으로
ssh -i ~/.ssh/doktori-loadtest.pem ubuntu@13.124.202.148 "tail -30 \$(ls -t /tmp/k6-*.log | head -1)"
```

## 러너 관리

```bash
./run-distributed.sh --status     # 러너 상태 확인 (IP, running/stopped)
./run-distributed.sh --stop       # 인스턴스 중지 (비용 절약)
./run-distributed.sh --start      # 인스턴스 시작 (1-2분 후 SSH 가능)
```

## 권장 실행 순서 (업무 시간 09:00~18:00)

| 시간 | 명령어 | 목적 |
|------|--------|------|
| 09:00 | `./run-distributed.sh smoke --pull --prom` | API 정상 확인 + 코드 반영 |
| 09:15 | `./run-distributed.sh guest-flow --prom` | 비회원 흐름 |
| 09:30 | `./run-distributed.sh user-flow --prom` | 로그인 사용자 흐름 |
| 10:00 | `./run-distributed.sh meeting-search --prom` | 검색 병목 |
| 10:30 | `./run-distributed.sh chat-api --prom` | 채팅 REST API |
| 11:00 | `./run-distributed.sh chat-ws --prom` | 채팅 WebSocket |
| 13:00 | `./run-distributed.sh load --prom` | SLO 통과 확인 (300 VU, 16분) |
| 14:00 | `./run-distributed.sh stress --prom` | K8s 한계점 (1500 VU, 13분) |
| 14:30 | `./run-distributed.sh spike --prom` | HPA 반응 속도 (5분) |
| 15:00 | `./run-distributed.sh soak --prom` | 장시간 안정성 (1시간) |
| 16:30 | `./run-distributed.sh --result` | 결과 수집 |
| 17:00 | Grafana 스크린샷 | 결과 기록 |
| 18:00 | `./run-distributed.sh --stop` | 러너 중지 |

## SLO 기준

| SLO | 지표 | 목표 |
|-----|------|------|
| SLO-1 | API 가용성 (5xx 비율) | < 0.5% |
| SLO-2 | 핵심 API Latency P95 | ≤ 1,000ms |
| SLO-3 | Chat 서비스 가용성 | 99.0% |
| SLO-4 | 모임 가입 성공률 | 99.0% |

## 트러블슈팅

### 러너에서 k6 안 됨

```bash
ssh -i ~/.ssh/doktori-loadtest.pem ubuntu@<IP>
curl -fsSL https://github.com/grafana/k6/releases/download/v0.54.0/k6-v0.54.0-linux-arm64.tar.gz \
  | sudo tar xz --strip-components=1 -C /usr/local/bin
k6 version
```

### Grafana 접속 안 됨

```bash
ssh -i ~/.ssh/doktori-loadtest.pem ubuntu@13.124.202.148
cd /home/ubuntu/monitoring
docker compose ps       # 컨테이너 상태 확인
docker compose up -d    # 재시작
docker compose logs     # 로그 확인
```

### git pull 권한 에러

```bash
# 레포 소유권이 root로 되어있을 때
ssh -i ~/.ssh/doktori-loadtest.pem ubuntu@<IP>
sudo chown -R ubuntu:ubuntu /home/ubuntu/5-team-service-cloud
```

### Prometheus에 메트릭이 안 들어옴

1. `--prom` 옵션으로 실행했는지 확인
2. Prometheus UI(http://13.124.202.148:9090) → Status → TSDB Status 확인
3. SG에 9090 포트 열려있는지 확인

### 인스턴스 재생성 필요 시

```bash
cd terraform/environments/loadtest
terraform taint 'aws_instance.runner[0]'
terraform apply
```

## Terraform

```bash
cd terraform/environments/loadtest

terraform plan                              # 변경 사항 확인
terraform apply                             # 적용
terraform output                            # IP, 접속 정보 확인
terraform destroy                           # 전체 삭제 (테스트 완전 종료 시)
```

- AWS 프로필: `doktori-first` (Account: 246477585940)
- State: 로컬 (`terraform.tfstate`)
- SSH 키: `~/.ssh/doktori-loadtest.pem`