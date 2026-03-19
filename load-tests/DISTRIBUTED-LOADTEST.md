# 분산 부하테스트 운영 가이드

> 별도 AWS 계정(doktori-first)의 EC2 러너 3대에서 프로덕션(api.doktori.kr)에 부하를 생성한다.
> 결과는 러너 1의 Grafana에서 실시간 모니터링한다.

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
| SSM (러너 1) | `aws --profile doktori-first ssm start-session --target i-08916422bc5d32aa5` | |
| SSM (러너 2) | `aws --profile doktori-first ssm start-session --target i-05c2a365e8f740d44` | |
| SSM (러너 3) | `aws --profile doktori-first ssm start-session --target i-0c6a1059d63d2629c` | |

## 부하테스트 실행

### 기본 실행 (Grafana 연동)

```bash
cd load-tests

PROM_REMOTE_WRITE_URL="http://13.124.202.148:9090/api/v1/write" \
  ./run-distributed.sh <시나리오> --pull
```

`--pull`은 러너에서 최신 코드를 가져온다. 코드 변경 후 첫 실행 시 사용.

### 시나리오 목록

#### 표준 부하 패턴

```bash
# 1. Smoke — 기능 검증 (5 VU, 1분)
./run-distributed.sh smoke

# 2. Load — 일반 트래픽 (50→100 VU × 3대 = 최대 300 VU, 16분)
./run-distributed.sh load

# 3. Stress — 한계 탐색 (100→500 VU × 3대 = 최대 1500 VU, 13분)
./run-distributed.sh stress

# 4. Spike — 급증 복구력 (100→500→100 VU, 5분)
./run-distributed.sh spike

# 5. Soak — 장시간 안정성 (50 VU, 1시간)
./run-distributed.sh soak
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

### Grafana 없이 실행

```bash
# PROM_REMOTE_WRITE_URL을 안 넣으면 k6 결과만 로그로 저장
./run-distributed.sh load --pull
```

## 실행 후

### 상태 확인

```bash
# 실행 상태 (실행 시 출력된 command-id 사용)
./run-distributed.sh --status <command-id>
```

### Grafana에서 결과 보기

1. http://13.124.202.148:3000 접속
2. Dashboards → **k6 Prometheus (Native Histograms)** 선택
3. 시간 범위를 테스트 기간에 맞게 조정

주요 패널:
- **Virtual Users**: VU 수 추이 (ramp up/down)
- **HTTP Request Rate**: 초당 요청 수
- **HTTP Request Duration**: P50/P90/P95/P99 응답시간
- **HTTP Failure Rate**: 에러율
- **Data Transfer**: 바이트/초

### 결과 로그 확인

각 러너의 `/tmp/k6-<timestamp>.log`에 결과가 저장된다.

```bash
# SSM 접속 후
cat /tmp/k6-*.log | grep -E '(http_req_duration|http_req_failed|errors)'
```

## 러너 관리

```bash
# 테스트 끝나면 인스턴스 중지 (비용 절약)
./run-distributed.sh --stop

# 다시 시작
./run-distributed.sh --start
```

## 권장 실행 순서 (업무 시간 09:00~18:00)

| 시간 | 시나리오 | 목적 |
|------|----------|------|
| 09:00~09:30 | `smoke --pull` | API 정상 동작 확인 + 최신 코드 반영 |
| 09:30~10:00 | `guest-flow`, `user-flow` | 사용자 여정별 기본 성능 |
| 10:00~11:00 | `meeting-search`, `chat-api` | 개별 병목 확인 |
| 11:00~12:00 | `chat-ws`, `notification` | 채팅/알림 서비스 부하 |
| 13:00~14:00 | `load` | SLO 기준 통과 확인 (300 VU) |
| 14:00~15:00 | `stress` | K8s 한계점 탐색 (1500 VU) |
| 15:00~15:15 | `spike` | HPA 반응 속도 확인 |
| 15:15~16:30 | `soak` | 장시간 안정성 (메모리 누수, 커넥션 풀) |
| 16:30~17:30 | 재검증 or 개별 시나리오 반복 | 문제 발견 시 재현 |
| 17:30~18:00 | Grafana 스크린샷 + 정리 | 결과 기록 |
| 18:00 | `--stop` | 러너 중지 |

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
# SSM 접속 후 수동 설치
curl -fsSL https://github.com/grafana/k6/releases/download/v0.54.0/k6-v0.54.0-linux-arm64.tar.gz \
  | sudo tar xz --strip-components=1 -C /usr/local/bin
k6 version
```

### Grafana 접속 안 됨

```bash
# SSM으로 러너 1 접속 후
cd /home/ubuntu/monitoring
docker compose ps       # 컨테이너 상태 확인
docker compose up -d    # 재시작
docker compose logs     # 로그 확인
```

### Prometheus에 메트릭이 안 들어옴

1. k6 실행 시 `PROM_REMOTE_WRITE_URL` 설정 확인
2. Prometheus UI(http://13.124.202.148:9090) → Status → TSDB Status 확인
3. 러너 → Prometheus 네트워크 연결 확인 (같은 VPC이므로 SG만 확인)

### 인스턴스 재생성 필요 시

```bash
cd terraform/environments/loadtest
terraform taint 'aws_instance.runner[0]'  # 교체할 러너 번호
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

AWS 프로필: `doktori-first` (Account: 246477585940)
State: 로컬 (`terraform.tfstate`)