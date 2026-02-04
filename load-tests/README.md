# Doktori 부하테스트

k6 기반 부하테스트 스크립트입니다.

## 설치

```bash
# macOS
brew install k6

# Linux
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update
sudo apt-get install k6
```

## 디렉토리 구조

```
load-tests/
├── k6/
│   ├── config.js           # 환경 설정 (BASE_URL, 토큰 등)
│   ├── helpers.js          # 공통 유틸 함수
│   └── scenarios/
│       ├── smoke.js        # Smoke 테스트 (기능 검증)
│       ├── load.js         # Load 테스트 (일반 부하)
│       ├── stress.js       # Stress 테스트 (한계점 확인)
│       ├── spike.js        # Spike 테스트 (급격한 트래픽)
│       ├── soak.js         # Soak 테스트 (장시간 안정성)
│       ├── guest-flow.js   # 비회원 탐색 흐름
│       ├── user-flow.js    # 로그인 사용자 흐름
│       ├── meeting-search.js   # 모임 검색 병목 테스트
│       └── join-meeting.js     # 모임 참여 동시성 테스트
└── README.md
```

## 실행 방법

### 환경 변수 설정

```bash
export BASE_URL="https://api.doktori.com/api"
export JWT_TOKEN="your-jwt-token"
```

### Smoke 테스트 (기능 검증)

```bash
k6 run k6/scenarios/smoke.js
```

### Load 테스트 (일반 부하)

```bash
k6 run k6/scenarios/load.js
```

### 특정 시나리오 실행

```bash
# 비회원 탐색 흐름
k6 run k6/scenarios/guest-flow.js

# 모임 검색 병목 테스트
k6 run k6/scenarios/meeting-search.js

# 모임 참여 동시성 테스트 (정원 레이스 컨디션)
k6 run k6/scenarios/join-meeting.js
```

### 결과 출력 옵션

```bash
# JSON 출력
k6 run --out json=results.json k6/scenarios/load.js

# InfluxDB로 전송 (Grafana 연동)
k6 run --out influxdb=http://localhost:8086/k6 k6/scenarios/load.js

# HTML 리포트 (k6-reporter 플러그인 필요)
k6 run --out json=results.json k6/scenarios/load.js
```

## SLO 기준

| 지표 | 목표 |
|------|------|
| 응답시간 P95 | < 500ms (읽기), < 1000ms (쓰기) |
| 응답시간 P99 | < 1500ms |
| 에러율 | < 1% |
| 처리량 | 최소 100 RPS |

## 테스트 전 준비사항

1. **테스트 환경 분리**: 프로덕션 환경에서 실행 금지
2. **테스트 데이터**: 충분한 모임, 사용자, 회차 데이터 사전 생성
3. **JWT 토큰**: 아래 자동화 스크립트 사용
4. **모니터링**: Prometheus/Grafana 대시보드 준비

## JWT 토큰 자동 획득

카카오 로그인 후 Access Token을 자동으로 가져오는 스크립트:

```bash
cd scripts
npm install
```

**사용 전 설정** (`scripts/get-token.js`의 CONFIG 수정):

```javascript
const CONFIG = {
  oauthUrl: 'https://your-api.com/api/oauth/kakao',      // 실제 OAuth URL
  frontendUrl: 'https://your-frontend.com',              // 프론트엔드 URL
};
```

**실행:**

```bash
# 브라우저 열림 (처음 로그인 시)
npm run get-token

# 헤드리스 모드 + .env 저장 (로그인 세션 유지된 후)
npm run get-token:headless
```

처음 실행 시 카카오 로그인 필요 → 이후에는 세션 유지되어 자동 로그인