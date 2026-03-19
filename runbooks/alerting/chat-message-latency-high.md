# Chat Message P95 Latency > 500ms

| 항목 | 값 |
|------|-----|
| Alert UID | `chat_message_latency_high` |
| Severity | Warning |
| 조건 | `chat_message_send_seconds` P95 > 500ms — 5분 지속 |
| 의미 | 채팅 메시지 처리(DB INSERT + 브로드캐스트) 지연 → 사용자 체감 지연 |

---

## 1. 즉시 확인

```promql
# 메시지 처리 P95 추이
histogram_quantile(0.95,
  sum by (le) (
    rate(chat_message_send_seconds_bucket{env="prod"}[5m])
  )
)

# 동시 WebSocket 세션 수
chat_ws_sessions_active{env="prod"}
```

## 2. 원인 진단

### 2-1. DB slow query
- 메시지 INSERT 쿼리 지연 여부 확인
- MySQL 대시보드에서 slow query 확인
- `hikaricp_connections_pending{env="prod", app="chat"}` > 0이면 DB 병목

### 2-2. JVM GC pause
```promql
jvm_gc_pause_seconds_max{env="prod", app="chat"}
```
- GC pause > 200ms이면 GC 튜닝 필요

### 2-3. 동시 접속 급증
```promql
chat_ws_sessions_active{env="prod"}
```
- 평소 대비 세션 수 급증 → 브로드캐스트 부하

### 2-4. 로그 확인
```logql
{app="chat", env="prod", level="WARN"} | json | message =~ ".*slow.*|.*timeout.*"
```

## 3. 대응

| 원인 | 조치 |
|------|------|
| DB slow query | 메시지 테이블 인덱스 확인, 개발팀에 전달 |
| GC pause | `-Xmx` 힙 사이즈 조정, G1GC 튜닝 |
| 동시 접속 급증 | 브로드캐스트 방식 확인, 스케일아웃 검토 |
| CPU 부족 | Chat 컨테이너 CPU 제한 확인 |

## 4. 복구 확인

- [ ] `chat_message_send_seconds` P95 < 500ms
- [ ] Grafana alert resolved 알림 수신
- [ ] 사용자 체감 지연 없음 확인 (프론트엔드 테스트)

## 관련 대시보드

- [Application](http://13.125.29.187:3000/d/application)
- [Logs (Chat)](http://13.125.29.187:3000/d/logs?var-app=chat&var-env=prod&from=now-15m&to=now)