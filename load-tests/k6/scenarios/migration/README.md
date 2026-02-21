# 무중단 마이그레이션 부하 테스트

> Lightsail → VPC 무중단 마이그레이션의 각 단계에서 서비스 가용성을 검증하는 부하 테스트 모음

## 테스트 시나리오

| 시나리오 | 파일 | 적용 시점 | VU | 시간 | 목적 |
|----------|------|-----------|:--:|:----:|------|
| DB 컷오버 | `db-cutover-traffic.js` | Master read_only → RDS 승격 | 20 | 10분 | 읽기 가용성 99%+, 쓰기 실패 수 측정 |
| DNS 전환 | `dns-switch-availability.js` | Route 53 A레코드 변경 | 22 | 30분 | 전체 가용성 99.9%+, 에러 0건 |
| 커넥션 풀 | `connection-pool-resilience.js` | DB 엔드포인트 전환 | 16 | 10분 | 복구 시간 측정, 자동 재연결 확인 |
| WebSocket | `websocket-migration.js` | Chat 서버 전환 | 8 | 15분 | 연결 끊김 여부, 재연결 패턴 |
| 사용자 여정 | `full-user-journey.js` | 모든 마이그레이션 단계 | 20 | 15분 | 5가지 시나리오 성공률 95%+ |

## 사전 준비

```bash
# k6 설치
brew install k6

# 환경변수 설정
export BASE_URL=https://doktori.kr/api
export JWT_TOKEN=<브라우저 개발자도구에서 복사한 토큰>
export WS_URL=wss://doktori.kr/ws
export TEST_MEETING_ID=1
```

## 실행 방법

```bash
# 개별 실행
./run-migration-test.sh db-cutover
./run-migration-test.sh dns-switch
./run-migration-test.sh connpool
./run-migration-test.sh websocket
./run-migration-test.sh full-journey

# JSON 출력 (Grafana 시각화용)
./run-migration-test.sh db-cutover --json

# 전체 순차 실행 (~80분)
./run-migration-test.sh all
```

## 마이그레이션 단계별 실행 가이드

### Phase 5-6: DB 컷오버 (Master → RDS)

```
터미널 1: ./run-migration-test.sh db-cutover
터미널 2: 컷오버 절차 실행 (read_only → 승격 → 전환)

관찰:
  - migration_read_success → 99%+ (읽기는 계속 되어야 함)
  - migration_write_failed_during_cutover → 이 수가 쓰기 실패 건수
  - 쓰기 실패 구간의 시작~끝 = 쓰기 불가 구간
```

### Phase 9: 서비스 배포 + 엔드포인트 전환

```
터미널 1: ./run-migration-test.sh connpool
터미널 2: 앱 DB 엔드포인트를 RDS로 변경 + 재시작

관찰:
  - connpool_connection_errors → 에러 시작 시점
  - "복구 감지!" 로그 → HikariCP 재연결 완료 시점
  - 시작~복구 시간 차이 = 커넥션 풀 복구 시간
```

### Phase 10: Nginx 라우팅 전환

```
터미널 1: ./run-migration-test.sh websocket
터미널 2: Nginx upstream을 새 VPC 서비스로 변경 + reload

관찰:
  - ws_disconnections → WebSocket 끊김 수
  - "WS 연결 끊김 (유지 시간: Xs)" → 끊기는 시점
```

### Phase 11: DNS 전환

```
터미널 1: ./run-migration-test.sh dns-switch     (30분)
터미널 2: ./run-migration-test.sh full-journey   (15분, 별도)
터미널 3: Route 53 A레코드 변경

관찰:
  - dns_availability → 99.9%+ (무중단 증명)
  - dns_failed_requests → 0건이 목표
  - 시간축 그래프에서 전환 전후 변동 없음 확인
```

## 포트폴리오 산출물

각 테스트에서 수집하는 핵심 데이터:

| 메트릭 | 의미 | 포트폴리오 활용 |
|--------|------|----------------|
| `migration_read_success` | DB 컷오버 중 읽기 가용성 | "컷오버 중에도 읽기 99.X% 가용" |
| `migration_write_failed_during_cutover` | 쓰기 실패 건수 | "쓰기 불가 구간 X초, Y건 실패" |
| `dns_availability` | DNS 전환 중 전체 가용성 | "DNS 전환 중 가용성 99.9%" |
| `dns_failed_requests` | DNS 전환 중 실패 수 | "전환 중 에러 0건 = 무중단" |
| `connpool_connection_errors` | 커넥션 에러 수 | "HikariCP 자동 복구 X초" |
| `ws_disconnections` | WebSocket 끊김 수 | "WebSocket 전환 시 X건 끊김, Y초 내 재연결" |
| `journey_overall_success` | 사용자 시나리오 성공률 | "마이그레이션 중 5가지 시나리오 성공률 9X%" |

## 결과 파일 위치

```
load-tests/result/migration/
├── db-cutover-YYYYMMDD-HHMMSS.log     # k6 콘솔 출력
├── db-cutover-YYYYMMDD-HHMMSS.json    # --json 옵션 시
├── dns-switch-YYYYMMDD-HHMMSS.log
├── connpool-YYYYMMDD-HHMMSS.log
├── websocket-YYYYMMDD-HHMMSS.log
└── full-journey-YYYYMMDD-HHMMSS.log
```
