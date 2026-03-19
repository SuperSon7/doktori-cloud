# API Error Budget Burn Rate High (SLO-1)

| 항목 | 값 |
|------|-----|
| Alert UID | `slo1_error_budget_burn` |
| Severity | Warning |
| 조건 | 1시간 burn rate > 5x — 5분 지속 |
| 의미 | 현재 속도로 1.4일 내 7일 Error Budget(0.5%) 소진 |

---

## Burn Rate 이해

```
burn rate = (실제 에러율) / (SLO 허용 에러율)

SLO: 99.5% 가용성 → 허용 에러율 = 0.5%
burn rate 1x = 정상 소진 속도 (7일간 예산 딱 맞게 소진)
burn rate 5x = 5배 속도 → 1.4일 만에 예산 소진
burn rate 10x = 0.7일 만에 예산 소진
```

## 1. 즉시 확인

```promql
# 현재 burn rate 확인
(
  sum(rate(http_server_requests_seconds_count{env="prod", app="api", status=~"5.."}[1h]))
  /
  sum(rate(http_server_requests_seconds_count{env="prod", app="api"}[1h]))
) / 0.005

# 에러 집중 엔드포인트
topk(5,
  sum by (uri, status) (
    rate(http_server_requests_seconds_count{env="prod", app="api", status=~"5.."}[1h])
  )
)
```

## 2. 판단 기준

| burn rate | 예산 소진 예상 | 조치 |
|-----------|--------------|------|
| 5~10x | 0.7~1.4일 | 원인 파악 + 수정 계획 |
| 10~20x | 8~17시간 | 긴급 수정, 기능 배포 중단 |
| 20x+ | 8시간 이내 | 즉시 롤백 |

## 3. 대응

### 배포 직후 발생 시
- 에러 급증 확인 → **이전 버전으로 롤백**
- 롤백 후 burn rate 정상화 확인

### 점진적 증가 시
- 에러 집중 엔드포인트 특정
- traceId로 실패 요청 추적 (Logs 대시보드)
- DB/외부 API 장애 여부 확인

### 안정화 조치
- **기능 배포 동결** (burn rate 1x 이하로 돌아올 때까지)
- 에러 원인 수정 PR 우선 처리
- 수정 배포 후 burn rate 추이 모니터링

## 4. 복구 확인

- [ ] burn rate < 5x로 하락
- [ ] ERROR 로그 발생 빈도 정상 수준
- [ ] Grafana alert resolved 알림 수신
- [ ] 배포 동결 해제 판단

## 관련 대시보드

- [Application](http://13.125.29.187:3000/d/application)
- [Logs (API ERROR)](http://13.125.29.187:3000/d/logs?var-app=api&var-env=prod&var-level=ERROR&from=now-1h&to=now)