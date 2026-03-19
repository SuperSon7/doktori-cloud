# API P95 Latency > 1s (SLO-2)

| 항목 | 값 |
|------|-----|
| Alert UID | `slo2_api_latency_p95` |
| Severity | Warning |
| 조건 | 핵심 API P95 응답시간 > 1,000ms — 5분 지속 |
| 대상 | `/api/auth/**`, `/api/meetings/**`, `/api/users/me/meetings/**` |

---

## 1. 즉시 확인

```promql
# 엔드포인트별 P95 응답시간
histogram_quantile(0.95,
  sum by (le, uri) (
    rate(http_server_requests_seconds_bucket{
      env="prod", app="api",
      uri=~"/api/auth/.*|/api/meetings/.*|/api/users/me/meetings/.*"
    }[5m])
  )
)
```

## 2. 원인 진단

### 2-1. DB 병목
```promql
# HikariCP 대기 커넥션
hikaricp_connections_pending{env="prod", app="api"}

# 커넥션 풀 사용률
hikaricp_connections_active{env="prod"} / hikaricp_connections_max{env="prod"}
```
- pending > 0 → DB 쿼리 병목
- MySQL 대시보드에서 slow query 확인

### 2-2. 외부 호출 지연
- 카카오 OAuth (`/api/auth/**`) → 카카오 API 상태 확인
- Zoom API (미팅 관련) → Zoom 서비스 상태 확인

### 2-3. JVM 리소스
```promql
# GC pause
jvm_gc_pause_seconds_max{env="prod", app="api"}

# 힙 메모리 사용률
jvm_memory_used_bytes{env="prod", app="api", area="heap"}
/ jvm_memory_max_bytes{env="prod", app="api", area="heap"}
```

### 2-4. 동시 요청 급증
- 트래픽 급증 여부: `rate(http_server_requests_seconds_count{env="prod", app="api"}[5m])` 추이 확인

## 3. 대응

| 원인 | 조치 |
|------|------|
| DB slow query | 개발팀에 쿼리 최적화 요청, 인덱스 확인 |
| HikariCP 포화 | `maximumPoolSize` 임시 증가 (환경변수) |
| 외부 API 지연 | timeout 설정 확인, circuit breaker 검토 |
| GC pause 잦음 | 힙 사이즈 조정, 메모리 누수 확인 |
| 트래픽 급증 | 스케일아웃 또는 rate limiting 검토 |

## 4. 복구 확인

- [ ] P95 응답시간 < 1,000ms
- [ ] HikariCP pending = 0
- [ ] Grafana alert resolved 알림 수신

## 관련 대시보드

- [Application](http://13.125.29.187:3000/d/application)
- [Logs (API)](http://13.125.29.187:3000/d/logs?var-app=api&var-env=prod&from=now-15m&to=now)