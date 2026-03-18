# Doktori 부하테스트

K8s 기반 프로덕션 인프라의 성능 한계를 검증하는 k6 부하테스트 스위트.

## 왜 이 테스트를 하는가

Doktori는 K8s 클러스터(API 2 replica + Chat 2 replica) 위에서 동작한다.
이 테스트는 다음을 검증한다:

- **Pod 오토스케일링 & 로드밸런싱**: 트래픽 증가 시 K8s HPA가 제대로 반응하는가
- **DB 커넥션 풀 (HikariCP)**: 동시 500+ 유저에서 커넥션 고갈이 발생하는가
- **코드 레벨 병목**: N+1 쿼리, 중복 서브쿼리, 인덱스 미사용 등 실제 코드 문제
- **Chat WebSocket**: STOMP 동시 연결 100+ 에서 메시지 전달 지연
- **SLO 충족 여부**: P95 ≤ 1000ms, 5xx < 0.5%

## 인증 방식

백엔드 `DevController`가 dev/staging/prod 프로필에서 활성화되어 있어, `/api/dev/tokens`로 테스트 유저 500명의 JWT를 한번에 발급받는다. 모든 멀티 유저 시나리오는 이 토큰을 VU별 라운드로빈으로 배정하여 **실제 다수 유저의 부하를 시뮬레이션**한다.

단일 토큰은 같은 유저의 데이터만 조회하므로 캐시 히트율이 비현실적으로 높아진다.
멀티 토큰을 써야 DB, Redis, 커넥션 풀에 의미 있는 부하가 발생한다.

## 아키텍처

```
분산 러너 (3x EC2, 별도 AWS 계정)
    │
    │ HTTPS (인터넷 경유)
    ▼
┌─────────────────────────────────┐
│  K8s Ingress (NGINX Gateway)    │  Rate limit: 20r/s per IP
├─────────────────────────────────┤
│  /api/*        → api-svc:8080   │  API Pod × 2 (300m~1G CPU)
│  /api/chat-*   → chat-svc:8081  │  Chat Pod × 2 (300m~1G CPU)
│  /ws/chat      → chat-svc:8081  │  WebSocket (STOMP)
└─────────────────────────────────┘
         │              │
     MySQL(RDS)    Redis / RabbitMQ
```

## 디렉토리 구조

```
load-tests/
├── k6/
│   ├── config.js               # BASE_URL, SLO 임계값, 부하 단계 정의
│   ├── helpers.js              # HTTP 헬퍼, 멀티 토큰, 메트릭 공통
│   └── scenarios/
│       │
│       │  ── 표준 부하 패턴 ──
│       ├── smoke.js            # 기능 검증 (5 VU, 1분)
│       ├── load.js             # 일반 트래픽 (50→100 VU, 멀티 유저)
│       ├── stress.js           # 한계점 탐색 (100→500 VU, 멀티 유저)
│       ├── spike.js            # 급증 복구력 (100→500→100 VU)
│       ├── soak.js             # 장시간 안정성 (50 VU, 1시간)
│       │
│       │  ── 사용자 여정 ──
│       ├── guest-flow.js       # 비회원 탐색 (추천→목록→상세→검색)
│       ├── user-flow.js        # 로그인 유저 (프로필→모임→알림)
│       │
│       │  ── 코드 병목 타겟 ──
│       ├── meeting-search.js   # 검색 중복 서브쿼리 (MeetingRepositoryImpl)
│       ├── my-meetings-n1.js   # N+1 문제 (toMyMeetingItem)
│       ├── today-meetings.js   # DATE() 인덱스 미사용
│       ├── join-meeting.js     # 동시 참여 레이스컨디션 (SELECT FOR UPDATE 누락)
│       │
│       │  ── 기능별 ──
│       ├── notification.js     # SSE 연결 + 알림 API
│       ├── cache-test.js       # Nginx 캐시 HIT율 검증
│       ├── image-upload.js     # S3 Presigned URL + 업로드
│       ├── create-meeting.js   # 모임 생성 전체 파이프라인
│       │
│       │  ── 채팅 서비스 ──
│       ├── chat-api.js         # 채팅방 REST API (목록/생성/입장/상세)
│       ├── chat-websocket.js   # STOMP WebSocket (연결/구독/메시지)
│       │
│       └── migration/          # 마이그레이션 전용 시나리오 (11개)
│
├── chat-script/                # 팀원 작성 — 채팅방 멀티유저 smoke
│   └── script_chatroom_multiuser_smoke.js
│
├── doktori-smoke/              # 통합 프로브 (전체 API 순회 + HTML 리포트)
│   ├── script_scenario2_probe.js
│   ├── run_k6_with_report.sh
│   └── generate_k6_table_report.mjs
│
├── run-all.sh                  # 전체 시나리오 순차 실행
├── run-single.sh               # 단일 시나리오 실행
└── setup.sh                    # k6 설치 스크립트
```

## 설치

```bash
# macOS
brew install k6

# Linux (ARM64 — EC2 러너)
sudo gpg --no-default-keyring \
  --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 \
  --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D68
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install -y k6
```

## 실행 방법

### 환경변수

```bash
export BASE_URL="https://doktori.kr/api"    # 프로덕션 API
export WS_URL="wss://doktori.kr/ws/chat"    # WebSocket (채팅 테스트용)
```

> JWT_TOKEN 수동 설정은 불필요 — 멀티 토큰 시나리오가 `/api/dev/tokens`에서 자동 발급

### Smoke (기능 검증)

```bash
k6 run k6/scenarios/smoke.js
```

### Load (일반 트래픽, 멀티 유저)

```bash
k6 run k6/scenarios/load.js
```

### Stress (한계점 탐색)

```bash
k6 run k6/scenarios/stress.js
```

### 채팅 WebSocket

```bash
k6 run --env CHAT_ROOM_IDS="1,2,3" k6/scenarios/chat-websocket.js
```

### 채팅 REST API

```bash
k6 run k6/scenarios/chat-api.js
```

### 특정 병목 테스트

```bash
# N+1 문제 검증
k6 run k6/scenarios/my-meetings-n1.js

# 검색 중복 서브쿼리
k6 run k6/scenarios/meeting-search.js

# 동시 참여 레이스컨디션 (멀티 토큰 필요)
export JWT_TOKENS="token1,token2,token3,..."
k6 run k6/scenarios/join-meeting.js
```

### 결과 출력

```bash
# JSON (Grafana 분석용)
k6 run --out json=result/load.json k6/scenarios/load.js

# HTML 리포트 (doktori-smoke)
cd doktori-smoke
ACCESS_TOKEN="..." VUS=30 DURATION=10m ./run_k6_with_report.sh
```

## 시나리오별 상세

### 표준 부하 패턴

| 시나리오 | VU | 시간 | 인증 | 목적 |
|---------|-----|------|------|------|
| smoke | 5 | 1분 | 선택 | API 정상 동작 확인 |
| **load** | 50→100 | 16분 | **멀티 토큰 (500명)** | SLO 충족 검증 |
| **stress** | 100→500 | 13분 | **멀티 토큰 (500명)** | K8s 한계점 탐색 |
| spike | 100→500→100 | 5분 | 혼합 | HPA 반응 속도 |
| soak | 50 | 1시간 | 혼합 | 메모리 누수, 커넥션 풀 고갈 |

### 코드 병목 타겟

| 시나리오 | 타겟 코드 | 문제 | 검증 방법 |
|---------|----------|------|----------|
| meeting-search | `MeetingRepositoryImpl.searchMeetings()` | JOIN Book 서브쿼리 2회 실행 | 검색 P95 측정 |
| my-meetings-n1 | `MeetingService.toMyMeetingItem()` | 10건 → 21 쿼리 (N+1) | 목록 P95 측정 |
| today-meetings | `WHERE DATE(start_at)` | DATE() 함수가 인덱스 무효화 | today P95 측정 |
| join-meeting | `MeetingService.joinMeeting()` | Check-then-Act (락 없음) | 정원 초과 여부 |

### 채팅 서비스

| 시나리오 | 프로토콜 | VU | 목적 |
|---------|---------|-----|------|
| **chat-websocket** | WebSocket (STOMP) | 5→100 | 동시 연결 한계, 메시지 지연 |
| **chat-api** | HTTP REST | 5→100 | 채팅방 CRUD 성능 |
| chat-script (팀원) | HTTP REST | 설정 가능 | 멀티유저 채팅방 생성/입장 |

### load.js 트래픽 배분

```
25% 비회원 탐색 — 추천/목록/상세/검색
25% 로그인 사용자 — 프로필/내모임/오늘모임/알림
15% 모임 검색 — 키워드+필터 조합
10% 도서 검색 — Kakao Book API 의존
10% 이미지 업로드 — S3 Presigned URL
10% 채팅방 API — 목록/상세
 5% 알림 API — 읽음 처리
```

## SLO 기준

| SLO | 지표 | 목표 |
|-----|------|------|
| SLO-1 | API 가용성 (5xx 비율) | < 0.5% |
| SLO-2 | 핵심 API Latency P95 | ≤ 1,000ms |
| SLO-3 | Chat 서비스 가용성 | 99.0% |
| SLO-4 | 모임 가입 성공률 | 99.0% |

## 분산 실행 (프로덕션 부하테스트)

별도 AWS 계정에 EC2 러너 3대를 Terraform으로 프로비저닝한다.

```bash
cd terraform/environments/loadtest
terraform init && terraform plan
# 확인 후 apply
```

각 러너에 SSM으로 접속 (user_data가 k6 + git clone 자동 설치):

```bash
aws --profile doktori-loadtest ssm start-session --target <instance-id>

# 러너 안에서
cd /home/ubuntu/5-team-service-cloud/load-tests
export BASE_URL="https://doktori.kr/api"

# 3대 동시 실행 → VU 합산
k6 run k6/scenarios/load.js       # 러너당 100 VU = 총 300 VU
k6 run k6/scenarios/stress.js     # 러너당 500 VU = 총 1500 VU
```

## 기존 결과

`result/` 디렉토리에 baseline 비교 리포트:

- `baseline-before-step1.html` — 최적화 전
- `baseline-after-step1.html` — 1차 개선 후
- `baseline-after-step3_fix_n_plus1.html` — N+1 수정 후
- `baseline-after-step3_fix_HikariCP_20.html` — 커넥션 풀 튜닝 후
- `migration/` — 마이그레이션 테스트 결과