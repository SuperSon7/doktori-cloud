# Notification Delivery Failure Rate > 20%

| 항목 | 값 |
|------|-----|
| Alert UID | `notification_delivery_failure` |
| Severity | Warning |
| 조건 | `notification_delivery_total{result="failure"}` 비율 > 20% — 3분 지속 |
| 의미 | RabbitMQ consumer에서 SSE/FCM 알림 전달 실패 급증 |

---

## 1. 즉시 확인

```promql
# 전달 실패율 추이
sum(rate(notification_delivery_total{env="prod", result="failure"}[5m]))
/
sum(rate(notification_delivery_total{env="prod"}[5m]))

# 실패 건수
sum(increase(notification_delivery_total{env="prod", result="failure"}[5m]))
```

## 2. 원인 진단

### 2-1. RabbitMQ 상태
```bash
# RabbitMQ 관리 콘솔 또는 CLI
docker exec rabbitmq rabbitmqctl list_queues name messages consumers

# DLQ 적재량 확인
docker exec rabbitmq rabbitmqctl list_queues name messages | grep dlq
```
- DLQ에 메시지 쌓임 → consumer 처리 실패

### 2-2. FCM 토큰 문제
- 만료/해제된 디바이스 토큰으로 전송 시도
- API 로그에서 FCM 관련 에러 확인:
```logql
{app="api", env="prod", level="ERROR"} | json | message =~ ".*FCM.*|.*firebase.*|.*notification.*"
```

### 2-3. SSE 연결 문제
- 클라이언트 SSE 연결 끊김
- Nginx proxy buffering 설정 확인

### 2-4. API 서버 리소스
- 메모리/CPU 부족으로 consumer 처리 지연
- HikariCP 커넥션 풀 고갈

## 3. 대응

| 원인 | 조치 |
|------|------|
| DLQ 적재 | DLQ 메시지 확인 후 원인 분석, 재처리 또는 폐기 |
| FCM 토큰 만료 | 만료 토큰 정리 배치 실행 요청 (개발팀) |
| RabbitMQ 연결 끊김 | RabbitMQ 컨테이너 상태 확인 → 재시작 |
| API 서버 과부하 | consumer prefetch count 조정, 스케일아웃 검토 |

## 4. 복구 확인

- [ ] 실패율 < 20% 하락
- [ ] DLQ 적재량 증가 멈춤
- [ ] Grafana alert resolved 알림 수신
- [ ] 실제 알림 수신 테스트 (앱에서 알림 트리거)

## 관련 대시보드

- [Application](http://13.125.29.187:3000/d/application)
- [Logs (API ERROR)](http://13.125.29.187:3000/d/logs?var-app=api&var-env=prod&var-level=ERROR&from=now-15m&to=now)