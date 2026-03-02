# DNS 컷오버 모니터링 계획

## 1. 서비스 상황

### 현재 (이전 인프라)
- **단일 Lightsail 인스턴스** (다른 AWS 계정)에 앱 + DB 동거
- 앞단에 nginx → 뒤에 Spring Boot API, Chat, AI, Frontend 모노리스 구성
- DB는 이미 RDS로 마이그레이션 완료 (binlog replication → cutover)
- 도메인: `doktori.kr` → 현재 Lightsail IP를 가리킴

### 목표 (새 인프라)
- **컨테이너화된 분리 인스턴스** 구성 (prod VPC, 새 AWS 계정)

| 인스턴스 | 서비스 | 타입 | 서브넷 |
|----------|--------|------|--------|
| nginx | 리버스 프록시 + TLS | t4g.micro | public (EIP: 3.34.245.126) |
| front | Next.js | t4g.small | private |
| api | Spring Boot API | t4g.small | private |
| chat | Spring Boot Chat | t4g.micro | private |
| ai | FastAPI | t4g.small | private |
| RDS | MySQL 8.0 | db.t4g.small | private (multi-AZ) |

### 컷오버 방식
- Route53 A 레코드를 Lightsail IP → 새 nginx EIP(`3.34.245.126`)로 변경
- TTL 60초로 사전 조정 → 전파 후 점진적 트래픽 이동

---

## 2. 제약 조건

| 제약 | 설명 | 영향 |
|------|------|------|
| 다른 AWS 계정 | 이전 인프라는 별도 계정의 Lightsail | Route53 Hosted Zone 이전 필요, ACM 인증서 재발급 |
| DNS TTL 전파 | 클라이언트 DNS 캐시로 즉시 전환 불가 | 최대 TTL 시간 동안 구/신 혼재 |
| SSL 인증서 | 새 인프라에서 certbot 재발급 | DNS 전파 후에만 가능 (HTTP-01 challenge) |
| DB 이미 이전 완료 | RDS에 쓰기 중 | 구 서버 앱이 아직 구 DB? 신 DB? 확인 필요 |
| Private 서브넷 | app 인스턴스 직접 접근 불가 | SSM으로만 관리, outbound는 NAT 경유 |

---

## 3. 컷오버 시 트래픽 처리 옵션

> DNS 전환 후 TTL이 만료되지 않은 클라이언트는 여전히 이전 서버 IP로 요청을 보냄.
> 이 요청을 어떻게 처리할 것인가?

### Option A: 이전 서버 유지 (자연 소멸)
- 이전 서버의 앱을 그대로 살려두고 요청 처리
- TTL 만료되면 자연스럽게 트래픽 0으로 감소
- **장점**: 사용자 영향 없음, 구현 단순
- **단점**: 이전 서버 앱이 신 DB를 봐야 데이터 정합성 유지, 양쪽 앱 관리 부담

### Option B: 이전 서버 nginx에서 301 리다이렉트
- 이전 서버 nginx가 새 인프라 IP/도메인으로 리다이렉트
- **장점**: 강제로 새 인프라로 유도, 이전 앱 종료 가능
- **단점**: API 요청은 301 처리 불가 (클라이언트가 따라가지 않음), 브라우저만 유효

### Option C: 이전 서버 nginx에서 proxy_pass (리버스 프록시)
- 이전 nginx → 새 nginx로 프록시
- **장점**: API 포함 모든 요청을 새 인프라로 전달, 사용자 투명
- **단점**: 이전 서버가 중간 홉으로 남아 레이턴시 추가, 이전 서버 장애 시 영향

> **결정 필요**: TODO

---

## 4. 모니터링 항목 — 무엇을, 왜

### 4-1. DNS 전파 추적
> TODO: 상세 작성

- `dig doktori.kr +short` 결과가 새 EIP인지 확인
- 여러 DNS resolver(8.8.8.8, 1.1.1.1, ISP)에서 교차 확인
- **왜**: TTL이 만료되지 않은 resolver가 있으면 구 서버로 트래픽이 계속 감

### 4-2. 트래픽 분배 (구/신 비교)
> TODO: 상세 작성

- 이전 서버 nginx access.log request count
- 새 서버 nginx request count (`nginx_http_requests_total`)
- **왜**: 컷오버 진행률을 실시간으로 판단하기 위해. 구 서버 트래픽이 0이 되어야 정리 가능

### 4-3. HTTP 에러율
> TODO: 상세 작성

- 새 인프라 nginx 5xx 비율 (`rate(nginx_http_requests_total{status=~"5.."}[1m])`)
- upstream 연결 실패 (`connect() failed` in error.log)
- **왜**: 새 인프라 서비스 장애를 즉시 감지. 5xx > 5%면 DNS 롤백 트리거
- **기존 대시보드**: `nginx-observability.json`, `http-red.json`

### 4-4. 응답 레이턴시
> TODO: 상세 작성

- nginx upstream response time (`nginx_http_upstream_response_time`)
- Spring Boot p99 latency (`http_server_requests_seconds`)
- **왜**: 새 인프라가 이전보다 느리면 사용자 경험 저하. 기준: API < 1s, AI < 5s
- **기존 대시보드**: `nginx-observability.json`, `jvm-api.json`

### 4-5. 서비스 Health
> TODO: 상세 작성

- `up{env="prod"}` — 모든 인스턴스 Alloy push 정상 여부
- Blackbox probe (`probe_success{env="prod"}`) — 외부에서 HTTPS 접근 확인
- Spring actuator (`process_uptime_seconds{env="prod"}`)
- **왜**: 개별 서비스 장애를 빠르게 식별. 특정 서비스만 문제면 해당 서비스만 롤백
- **기존 대시보드**: `overview.json`, `prod-ec2-resource.json`

### 4-6. 인프라 리소스
> TODO: 상세 작성

- CPU, Memory, Disk, Network per instance
- **왜**: 새 인프라 스펙이 부족한지 확인. 이전은 단일 서버, 새 인프라는 분산이라 개별 부하 패턴이 다를 수 있음
- **기존 대시보드**: `prod-ec2-resource.json`

### 4-7. DB 연결 상태
> TODO: 상세 작성

- HikariCP active/idle/pending connections
- RDS connections count
- **왜**: 컷오버 중 DB 연결 전환 실패 시 서비스 장애 직결
- **기존 대시보드**: `mysql.json`, `jvm-api.json`

### 4-8. 로그 모니터링
> TODO: 상세 작성

- Loki에서 `{env="prod"}` 에러 로그 실시간 확인
- `connect() failed`, `upstream timed out`, `Access denied` 등 키워드
- **왜**: 메트릭만으로 잡기 어려운 구체적 에러 원인 파악
- **기존 대시보드**: `logs.json`

---

## 5. 대시보드 구성 계획

### 기존 대시보드 활용

| 대시보드 | 컷오버 시 용도 | 수정 필요 |
|----------|--------------|----------|
| `prod-ec2-resource.json` | 인프라 리소스 모니터링 | env=prod 필터 확인 |
| `nginx-observability.json` | 5xx 비율, upstream 레이턴시 | prod nginx 메트릭 소스 확인 |
| `http-red.json` | HTTP Rate/Error/Duration | env 필터 추가 |
| `jvm-api.json` | API JVM + HikariCP | env=prod 필터 |
| `mysql.json` | RDS 연결 상태 | prod RDS 타겟 확인 |
| `logs.json` | 에러 로그 실시간 | env=prod 필터 |
| `overview.json` | 전체 서비스 상태 한눈에 | env=prod 필터 |

### 신규 대시보드 (TODO)

#### `dns-cutover.json` — 컷오버 전용 대시보드
> TODO: 상세 구성

포함할 패널:
- **트래픽 비교**: 구 서버 vs 새 서버 request count (실시간)
- **에러율 타임라인**: 5xx 비율 시계열 (컷오버 시점 annotation)
- **서비스 상태 매트릭스**: 각 서비스 up/down stat panel
- **롤백 판단 지표**: 5xx > 5% 알림 표시
- **DNS 전파 상태**: 외부 probe 결과

---

## 6. 알림 설정 (컷오버 시)
> TODO: 상세 작성

- 기존 alert rule 활용 (`Service Down`, `Error Rate`, `Probe Failure`)
- 컷오버 전용 임시 알림 추가 고려
- Discord `#alert-critical` 채널로 즉시 알림

---

## 7. 롤백 판단 기준
> TODO: 상세 작성

| 지표 | 임계값 | 액션 |
|------|--------|------|
| 5xx 비율 | > 5% (3분간) | DNS 롤백 |
| 서비스 down | 2개 이상 (3분간) | DNS 롤백 |
| 응답 시간 | p99 > 10s (5분간) | 원인 분석 후 판단 |
| 특정 서비스만 | 1개 서비스 장애 | 해당 서비스 롤백 |

---

## 8. 컷오버 타임라인 (TODO)
> 실행 순서 + 각 단계별 확인할 모니터링 지표 매핑