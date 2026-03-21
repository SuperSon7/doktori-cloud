# 알림 시스템 부하 검증 전략

## 알림 아키텍처 (코드 기반)

```
이벤트 발생 (모임 생성/참여/독후감 등)
    │
    ▼
NotificationService.createAndSend()
    │ DB 저장 (notification 테이블)
    │ 트랜잭션 커밋 후 →
    ▼
RabbitMQNotificationQueue.enqueue()
    │ RabbitMQ exchange → notification.delivery.queue
    ▼
NotificationDeliveryConsumer.consume()
    ├── SSE: SseEmitterService.sendToUsers()
    │     │ Redis Pub/Sub (notification:sse:{userId})
    │     ▼
    │   RedisSseSubscriber.onMessage()
    │     │ SseEmitterService.deliverToLocal()
    │     ▼
    │   SseEmitter.send() → 클라이언트
    │
    └── FCM: FcmService.sendToUsers()
          │ SSE 미연결 유저에게만
          ▼
        Firebase Cloud Messaging → 모바일 푸시
```

### 핵심 컴포넌트

| 컴포넌트 | 클래스 | 역할 |
|---------|--------|------|
| 알림 생성 | `NotificationService.createAndSend()` | DB 저장 + RabbitMQ 발행 |
| 메시지 큐 | `RabbitMQNotificationQueue` | 트랜잭션 커밋 후 RabbitMQ에 enqueue |
| 소비자 | `NotificationDeliveryConsumer` | RabbitMQ → SSE/FCM 분기 전달 |
| SSE 관리 | `SseEmitterService` | ConcurrentHashMap으로 emitter 관리, Redis Pub/Sub |
| Redis 브릿지 | `RedisSseSubscriber` | Redis 메시지 → 로컬 SSE emitter 전달 |
| 하트비트 | `SseEmitterService.sendHeartbeat()` | 30초마다 dead emitter 정리 |
| 재시도 | `NotificationDeliveryConsumer` | 실패 시 wait queue → 최대 3회 retry → DLQ |
| DevController | `/dev/trigger-notification/{userId}` | 테스트용 알림 트리거 |

### 멀티 Pod 환경에서의 SSE

**Redis Pub/Sub으로 Pod 간 SSE 브로드캐스트:**
- 유저가 Pod A에 SSE 연결 → Redis에 `notification:sse:connected:{userId}` 키 저장
- 알림 발생 → RabbitMQ → 소비 Pod가 Redis `notification:sse:{userId}` 채널에 publish
- Pod A의 `RedisSseSubscriber`가 수신 → `SseEmitter.send()`

**SSE timeout:** 30분 (`SSE_TIMEOUT = 30 * 60 * 1000L`)

## k6로 검증 가능한 것

### 1. 알림 API 성능 (이미 검증 중)
- `GET /notifications` — 목록 조회 (최근 3일)
- `GET /notifications/unread` — 읽지 않은 알림 존재 여부
- `PUT /notifications/{id}` — 읽음 처리
- `PUT /notifications` — 전체 읽음 처리

### 2. 알림 생성 → 조회 지연 (추가 가능)
```
VU A: POST /dev/trigger-notification/{userId}  → 알림 생성 (RabbitMQ 경유)
VU B: GET /notifications                       → 알림 목록에 나타나는지
```
- DB 저장 + RabbitMQ + 소비까지의 end-to-end 지연 측정
- 부하 시 RabbitMQ 큐 적체 여부 확인

### 3. 알림 폭주 (쓰기 부하의 부수 효과)
- load v2/stress에서 모임 생성/참여가 실행되면 **자동으로 알림이 생성**
- 별도 시나리오 불필요 — 프로덕션 Grafana에서 모니터링:
  - `notification.delivery` 메트릭 (success/failure/retried/permanent_failure)
  - RabbitMQ 큐 깊이 (`notification.delivery.queue`)
  - Redis 연결 수

### 4. SSE 동시 연결 (k6 한계 있음)
- k6 HTTP로 `GET /notifications/subscribe` 요청 가능
- 하지만 **SSE 이벤트 스트림을 실시간 파싱하는 건 불가** — 연결만 하고 timeout 대기
- 동시 연결 수 자체는 측정 가능 (emitter map 크기)

## k6로 검증 불가능한 것

| 항목 | 이유 | 대안 |
|------|------|------|
| SSE 실시간 수신 확인 | k6가 event-stream 파싱 미지원 | Playwright E2E 테스트 |
| FCM 푸시 도달 | 실제 모바일 디바이스 필요 | Firebase 콘솔 모니터링 |
| Redis Pub/Sub 지연 | 내부 통신이라 외부에서 측정 불가 | Spring Actuator + Prometheus |

## 추천 검증 시나리오

### A. 알림 트리거 + 폴링 검증 (k6)

```javascript
// 1. 알림 트리거
POST /dev/trigger-notification/{userId}

// 2. 폴링으로 도달 확인 (최대 5초)
for (let i = 0; i < 5; i++) {
  const res = GET /notifications
  if (res에 방금 생성한 알림이 있으면) → 성공, 지연 시간 기록
  sleep(1)
}
```

측정 가능: **알림 생성 → DB 저장 → 조회 가능까지 지연 시간**

### B. SSE 연결 수 스트레스 (k6)

```javascript
// 100~500 VU가 동시에 SSE 구독
GET /notifications/subscribe (timeout 30초)
// ConcurrentHashMap emitter 수, Redis connected 키 수 확인
```

측정 가능: **동시 SSE 연결 수용량, 하트비트 처리 성능**

### C. 프로덕션 모니터링 (Grafana)

부하테스트 중 확인할 메트릭:
- `notification.delivery{result="success"}` — 초당 전달 성공 수
- `notification.delivery{result="failure"}` — 실패 수
- `notification.delivery{result="retried"}` — 재시도 수
- RabbitMQ queue depth (`notification.delivery.queue`)
- Redis memory + connections
- API Pod CPU/Memory (SSE emitter가 메모리 점유)

## 우선순위

| 순위 | 액션 | 효과 |
|------|------|------|
| P0 | 부하테스트 중 프로덕션 Grafana에서 `notification.delivery` 메트릭 확인 | 별도 구현 없이 즉시 가능 |
| P1 | 알림 트리거 + 폴링 시나리오 추가 | 알림 end-to-end 지연 측정 |
| P2 | SSE 동시 연결 스트레스 | SSE emitter 한계 확인 |
| P3 | Playwright E2E로 SSE 실시간 수신 검증 | 부하테스트 영역 아님, 별도 진행 |