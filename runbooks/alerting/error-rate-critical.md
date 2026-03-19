# Error Rate > 50%

| 항목 | 값 |
|------|-----|
| Alert UID | `error_rate_critical` |
| Severity | Critical |
| 조건 | HTTP 5xx 비율 > 50% — 1분 지속 |
| 대상 | api, chat 서비스 |

---

## 1. 즉시 확인

```bash
# Grafana에서 에러율 추이 확인
# Application 대시보드 → HTTP RED → Error Rate 패널

# Loki에서 ERROR 로그 확인
{app="<알림의 app>", env="prod", level="ERROR"} | json
```

## 2. 원인 진단

### 2-1. 최근 배포 확인
```bash
# GitHub Actions 배포 이력 확인
gh run list --workflow=prod-deploy.yaml --limit=5
```
- 배포 직후 에러 급증 → **롤백 우선**

### 2-2. 에러 집중 엔드포인트 특정
```promql
# 엔드포인트별 에러율
sum by (uri, method, status) (
  rate(http_server_requests_seconds_count{env="prod", app="<app>", status=~"5.."}[5m])
)
```

### 2-3. traceId로 요청 추적
1. Logs 대시보드에서 ERROR 로그 클릭
2. `traceId` 필드 값 복사
3. Trace Lookup 패널에 입력 → 전체 요청 흐름 확인

## 3. 복구

| 원인 | 조치 |
|------|------|
| 배포 직후 | GitHub Actions로 이전 버전 재배포 |
| DB 장애 | MySQL/RDS 상태 확인 → HikariCP 풀 상태 확인 |
| 외부 API 장애 | 카카오 OAuth, Zoom API 등 상태 페이지 확인 |
| 특정 엔드포인트 | 해당 API 로직 긴급 수정 or 임시 비활성화 |

## 4. 복구 확인

- [ ] 에러율 50% 미만으로 하락
- [ ] ERROR 로그 발생 멈춤
- [ ] Grafana alert resolved 알림 수신

## 5. 에스컬레이션

50% 에러율은 서비스 절반 이상 장애 → **즉시 백엔드 개발자 호출**

배포 직후라면 원인 분석 전에 **롤백부터** 진행

## 관련 대시보드

- [Application](http://13.125.29.187:3000/d/application)
- [Logs (ERROR)](http://13.125.29.187:3000/d/logs?var-app=api&var-env=prod&var-level=ERROR&from=now-15m&to=now)