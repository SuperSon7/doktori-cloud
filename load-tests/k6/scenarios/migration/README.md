# 무중단 마이그레이션 부하 테스트

> Lightsail → VPC 무중단 마이그레이션의 각 단계에서 서비스 가용성을 검증하는 부하 테스트 모음

## 테스트 시나리오

| 시나리오 | 파일 | 적용 시점 | VU | 시간 | 목적 |
|----------|------|-----------|:--:|:----:|------|
| DB 컷오버 | `db-cutover-traffic.js` | Master read_only → RDS 승격 | 20 | 10분 | 읽기 가용성 99%+, 쓰기 실패 수 측정 |
| 데이터 무손실 | `data-integrity-verification.js` | DB 컷오버 전후 | 9 | 15분 | INSERT 부하 중 데이터 유실 0건 증명 |
| DNS 전환 | `dns-switch-availability.js` | Route 53 A레코드 변경 | 22 | 30분 | 전체 가용성 99.9%+, 에러 0건 |
| 커넥션 풀 | `connection-pool-resilience.js` | DB 엔드포인트 전환 | 16 | 10분 | 복구 시간 측정, 자동 재연결 확인 |
| WebSocket | `websocket-migration.js` | Chat 서버 전환 | 8 | 15분 | 연결 끊김 여부, 재연결 패턴 |
| 사용자 여정 | `full-user-journey.js` | 모든 마이그레이션 단계 | 20 | 15분 | 5가지 시나리오 성공률 95%+ |
| 서비스 배포 | `service-deploy-availability.js` | 컨테이너 배포(Blue/Green) | 16 | 10분 | 배포 중 가용성 99.9%+, cold start 측정 |
| Nginx 전환 | `nginx-switch-availability.js` | upstream 변경 + reload | 24 | 10분 | reload 무중단, 에러 0건 |

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
./run-migration-test.sh data-integrity
./run-migration-test.sh dns-switch
./run-migration-test.sh connpool
./run-migration-test.sh websocket
./run-migration-test.sh full-journey
./run-migration-test.sh service-deploy
./run-migration-test.sh nginx-switch

# JSON 출력 (Grafana 시각화용)
./run-migration-test.sh db-cutover --json

# 전체 순차 실행 (~115분)
./run-migration-test.sh all
```

## 마이그레이션 단계별 실행 가이드

### Phase 5-6: DB 컷오버 (Master → RDS)

```
터미널 1: ./run-migration-test.sh db-cutover
터미널 2: ./run-migration-test.sh data-integrity   (동시 실행)
터미널 3: 컷오버 절차 실행 (read_only → 승격 → 전환)
터미널 4: ../grafana/annotate.sh "DB Cutover Start"

관찰:
  - migration_read_success → 99%+ (읽기는 계속 되어야 함)
  - migration_write_failed_during_cutover → 이 수가 쓰기 실패 건수
  - integrity_write_succeeded → 성공한 쓰기가 전부 DB에 반영되었는지
  - 쓰기 실패 구간의 시작~끝 = 쓰기 불가 구간
```

### Phase 7: Reverse Replication + 데이터 검증

```
터미널 1: 08-setup-reverse-replication.sh (역방향 복제 설정)
터미널 2: 09-checksum-verify.sh (CHECKSUM 검증)

관찰:
  - CHECKSUM 100% 일치 → 데이터 정합성 증명
  - Reverse Replication 동작 → 안전한 롤백 가능
```

### Phase 9: 서비스 배포 (Blue/Green)

```
터미널 1: ./run-migration-test.sh service-deploy
터미널 2: ./run-migration-test.sh connpool         (동시 실행)
터미널 3: 컨테이너 배포 수행 (docker stop → run)
터미널 4: ../grafana/annotate.sh "Service Deploy Start"

관찰:
  - deploy_availability → 99.9%+ (무중단)
  - deploy_cold_start_detected → HikariCP 초기화 시간
  - connpool_connection_errors → 커넥션 에러 수
  - "복구 감지!" 로그 → HikariCP 재연결 완료 시점
```

### Phase 10: Nginx 라우팅 전환

```
터미널 1: ./run-migration-test.sh nginx-switch
터미널 2: ./run-migration-test.sh websocket         (동시 실행)
터미널 3: Nginx upstream 변경 + reload
터미널 4: ../grafana/annotate.sh "Nginx Switch"

관찰:
  - nginx_availability → 99.9%+ (무중단)
  - nginx_connection_resets → reload 시 연결 끊김 수
  - ws_disconnections → WebSocket 끊김 수
  - nginx_server_switch_detected → 서버 전환 감지
```

### Phase 11: DNS 전환

```
터미널 1: ./run-migration-test.sh dns-switch     (30분)
터미널 2: ./run-migration-test.sh full-journey   (15분, 별도)
터미널 3: Route 53 A레코드 변경
터미널 4: ../grafana/annotate.sh "DNS Switch"

관찰:
  - dns_availability → 99.9%+ (무중단 증명)
  - dns_failed_requests → 0건이 목표
  - 시간축 그래프에서 전환 전후 변동 없음 확인
```

## 롤백 시나리오

| 단계 | 롤백 스크립트 | 소요 시간 | 데이터 유실 |
|------|--------------|:---------:|:-----------:|
| DB 컷오버 | `07-cutover-rollback.sh` | ~3분 | Reverse Replication 시 0건 |
| 서비스 배포 | `10-service-rollback.sh` | ~2분 | 없음 |
| Nginx 전환 | `11-nginx-rollback.sh` | ~30초 | 없음 |
| DNS 전환 | Route 53 원복 | TTL 대기 | 없음 |

## 포트폴리오 산출물

각 테스트에서 수집하는 핵심 데이터:

| 메트릭 | 의미 | 포트폴리오 활용 |
|--------|------|----------------|
| `migration_read_success` | DB 컷오버 중 읽기 가용성 | "컷오버 중에도 읽기 99.X% 가용" |
| `migration_write_failed_during_cutover` | 쓰기 실패 건수 | "쓰기 불가 구간 X초, Y건 실패" |
| `integrity_write_succeeded` | 쓰기 성공 건수 | "N건 쓰기 성공, 전부 DB 반영, 유실 0건" |
| `dns_availability` | DNS 전환 중 전체 가용성 | "DNS 전환 중 가용성 99.9%" |
| `dns_failed_requests` | DNS 전환 중 실패 수 | "전환 중 에러 0건 = 무중단" |
| `connpool_connection_errors` | 커넥션 에러 수 | "HikariCP 자동 복구 X초" |
| `ws_disconnections` | WebSocket 끊김 수 | "WebSocket 전환 시 X건 끊김, Y초 내 재연결" |
| `journey_overall_success` | 사용자 시나리오 성공률 | "마이그레이션 중 5가지 시나리오 성공률 9X%" |
| `deploy_availability` | 배포 중 가용성 | "Blue/Green 배포 중 가용성 99.9%+" |
| `deploy_cold_start_detected` | Cold start 감지 | "HikariCP 초기화 X초" |
| `nginx_availability` | Nginx 전환 중 가용성 | "Nginx reload 무중단, 에러 0건" |
| `nginx_server_switch_detected` | 서버 전환 감지 | "upstream 전환 실시간 감지" |

## Grafana 대시보드

마이그레이션 전용 Grafana 대시보드가 포함되어 있습니다.

```bash
# 대시보드 임포트
# Grafana UI → Dashboards → Import → migration-dashboard.json 업로드
# 위치: Cloud/migration-practice/grafana/migration-dashboard.json

# Annotation 마커 (마이그레이션 이벤트 기록)
../../../migration-practice/grafana/annotate.sh "DB Cutover Start" "Master read_only"
../../../migration-practice/grafana/annotate.sh "DB Cutover End" "RDS 승격 완료"
```

## 결과 파일 위치

```
load-tests/result/migration/
├── db-cutover-YYYYMMDD-HHMMSS.log          # k6 콘솔 출력
├── db-cutover-YYYYMMDD-HHMMSS.json         # --json 옵션 시
├── data-integrity-YYYYMMDD-HHMMSS.log
├── dns-switch-YYYYMMDD-HHMMSS.log
├── connpool-YYYYMMDD-HHMMSS.log
├── websocket-YYYYMMDD-HHMMSS.log
├── full-journey-YYYYMMDD-HHMMSS.log
├── service-deploy-YYYYMMDD-HHMMSS.log
└── nginx-switch-YYYYMMDD-HHMMSS.log
```
