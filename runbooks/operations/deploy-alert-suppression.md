# 배포 중 알림 억제 전략

배포/재시작 시 발생하는 일시적 알림 노이즈를 처리하는 방법.

---

## 문제

Blue-Green 배포 시 다운타임 순서:
```
컨테이너 Recreate → MySQL healthcheck 대기 → Spring Boot 기동(~37초) → healthcheck 통과
= 최소 2~3분 서비스 불가
```

이 동안 발생하는 알림:
- **Service Down** — `up == 0` 감지
- **Service Restarted** — `changes(process_start_time_seconds)` 감지
- **Probe Failure** — blackbox exporter가 health 엔드포인트 실패 감지
- **Error Rate** — 일시적 5xx 스파이크

---

## 업계 사례 비교

| 접근법 | 사용 기업 | 동작 방식 | 우리 팀 적합도 |
|---|---|---|---|
| **Grafana Silence API** | 중소규모 팀 전반 | 배포 전 API로 특정 알림 억제, 배포 후 해제 | **즉시 도입 가능** |
| **PagerDuty Maintenance Window** | 중대규모 기업 | 서비스 단위 인시던트 억제 | 별도 유료 서비스 필요 |
| **배포 메트릭 조건 제외** | Google SRE | `deployment_in_progress` 메트릭으로 알림 조건 자체에서 제외 | 중기 도입 |
| **Multi-Window Burn Rate** | Google, SoundCloud, GitLab | SLO 기반 에러 버짓 소진율, 여러 시간 창 AND 조건 | 중기 도입 |
| **카나리 분석** | Netflix (Kayenta) | 배포 시 메트릭 자동 비교 + 자동 롤백 | 현재 규모에 과도 |
| **K8s PDB + Readiness Gate** | K8s 사용 기업 | 서비스 가용성 자체를 보장 | 현재 VM 환경 불가 |
| **`for` 절 조정** | 범용 | 감지 대기 시간을 배포 시간보다 길게 | **즉시 적용 (보조)** |

---

## Phase 1: 즉시 적용 (완료)

### A. `for` 절 조정

| 룰 | Before | After | 이유 |
|---|---|---|---|
| Service Down | 1m | **3m** | BG 전환이 2~3분 소요 |
| Probe Failure | 2m | **5m** | 배포 + Spring Boot 기동 시간 커버 |
| Service Restarted | 0s | 0s | 정보용 알림, `for` 조정 불가 (Silence 대상) |

### B. 이미 적용된 보호 장치

Application 룰(Error Rate, p99, HikariCP, GC Pause)에는 이미 `and on(instance) up == 1` 조건이 있어서 서비스 다운 중에는 평가를 건너뜀.

---

## Phase 2: Grafana Silence API 연동 (권장 — 1순위)

배포 스크립트에서 Grafana API로 자동 Silence 생성/삭제.

### 사전 준비

1. Grafana Service Account 생성:
   - Grafana UI → Administration → Service accounts → Add
   - Role: `Editor` (Silence 생성 권한 필요)
   - Token 발급 후 `.env`에 저장

2. `.env`에 추가:
```bash
GRAFANA_URL=http://<모니터링서버>:3000
GRAFANA_SA_TOKEN=glsa_xxxxxxxxxxxxxxxxxxxx
```

### deploy-prd.sh에 추가할 함수

```bash
SILENCE_DURATION_MINUTES=10

create_deploy_silence() {
  local starts_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local ends_at=$(date -u -d "+${SILENCE_DURATION_MINUTES} minutes" +"%Y-%m-%dT%H:%M:%SZ")

  SILENCE_ID=$(curl -s -X POST \
    "${GRAFANA_URL}/api/alertmanager/grafana/api/v2/silences" \
    -H "Authorization: Bearer ${GRAFANA_SA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"matchers\": [{
        \"name\": \"alertname\",
        \"value\": \"Service Down|Service Restarted|Probe Failure\",
        \"isRegex\": true,
        \"isEqual\": true
      }],
      \"startsAt\": \"${starts_at}\",
      \"endsAt\": \"${ends_at}\",
      \"createdBy\": \"deploy-prd.sh\",
      \"comment\": \"Deployment ${VERSION_TAG}\"
    }" | jq -r '.silenceID')

  echo "🔇 Silence created: ${SILENCE_ID} (${SILENCE_DURATION_MINUTES}분 자동 만료)"
}

delete_deploy_silence() {
  if [ -n "${SILENCE_ID:-}" ]; then
    curl -s -X DELETE \
      "${GRAFANA_URL}/api/alertmanager/grafana/api/v2/silence/${SILENCE_ID}" \
      -H "Authorization: Bearer ${GRAFANA_SA_TOKEN}"
    echo "🔔 Silence deleted: ${SILENCE_ID}"
  fi
}
```

### 배포 흐름에 통합

```bash
# deploy-prd.sh 메인 흐름
create_deploy_silence           # ← 배포 전 Silence 생성
trap delete_deploy_silence EXIT # ← 실패해도 자동 정리

# ... 기존 배포 로직 ...

delete_deploy_silence           # ← 정상 완료 시 즉시 해제
trap - EXIT                     # ← trap 해제
```

### 안전장치

- `endsAt`을 10분으로 설정 → Silence 삭제 실패해도 자동 만료
- `trap ... EXIT`로 스크립트 비정상 종료 시에도 Silence 정리 시도
- matcher가 특정 알림만 대상 → 디스크/메모리 등 인프라 알림은 억제 안 됨

---

## Phase 3: 배포 메트릭 조건 제외 (중기)

Google SRE 원칙 — 알림 규칙 자체에서 배포 상태를 인지.

### 구현 방법

1. 배포 스크립트에서 메트릭 push:
```bash
# 배포 시작
curl -X POST "http://<PROMETHEUS>:9090/api/v1/import/prometheus" \
  --data-binary 'deployment_in_progress{service="backend"} 1'

# 배포 완료
curl -X POST "http://<PROMETHEUS>:9090/api/v1/import/prometheus" \
  --data-binary 'deployment_in_progress{service="backend"} 0'
```

2. 알림 규칙에 조건 추가:
```yaml
expr: |
  up
  unless on() deployment_in_progress == 1
```

### 장점
- Silence 없이 구조적으로 해결
- 메트릭 기반이라 Grafana 대시보드에서 배포 시점 확인 가능

### 필요 조건
- Prometheus가 push 메트릭을 수신할 수 있어야 함 (Prometheus 3.x의 OTLP 또는 Pushgateway)

---

## Phase 4: SLO 기반 Multi-Window Burn Rate (중기)

Error Rate 알림을 Google SRE Workbook의 burn rate 방식으로 전환.

### 왜 배포 노이즈에 강한가?

```
배포 중 30초간 5xx 발생:
- rate(...[5m])  = 일시적으로 높음  ← 단독이면 알림 발생
- rate(...[1h])  = 1시간 평균이라 크게 안 오름
- 두 조건 AND   = 5분 창만 높으면 알림 안 감  ← 배포 면역!
```

### Prometheus Recording Rules 예시

```yaml
# prometheus/rules/slo-recording.yml
groups:
  - name: slo:api_availability
    interval: 30s
    rules:
      - record: slo:api_error_rate:ratio_rate5m
        expr: |
          sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
          / sum(rate(http_server_requests_seconds_count[5m]))
      - record: slo:api_error_rate:ratio_rate1h
        expr: |
          sum(rate(http_server_requests_seconds_count{status=~"5.."}[1h]))
          / sum(rate(http_server_requests_seconds_count[1h]))

  - name: slo:api_alerts
    rules:
      # SLO 99.9% → 에러 버짓 0.1%
      # 빠른 burn: 1시간 창에서 14.4x burn rate
      - alert: SLOBurnRateFast
        expr: |
          slo:api_error_rate:ratio_rate1h > (14.4 * 0.001)
          and
          slo:api_error_rate:ratio_rate5m > (14.4 * 0.001)
        for: 2m
        labels:
          severity: critical
```

### 도입 시기
- 현재 단순 임계값 알림이 잘 동작하고 있으므로, Silence API 도입 후 점진적 전환
- `Error Rate > 10%` / `> 50%` 를 burn rate로 먼저 교체

---

## 참고 자료

- [Google SRE Book — Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/)
- [Google SRE Workbook — Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)
- [Grafana Labs — Multi-window Multi-Burn-Rate Alerts](https://grafana.com/blog/how-to-implement-multi-window-multi-burn-rate-alerts-with-grafana-cloud/)
- [SoundCloud — Alerting on SLOs like Pros](https://developers.soundcloud.com/blog/alerting-on-slos/)
- [Netflix — Automated Canary Analysis with Kayenta](https://netflixtechblog.com/automated-canary-analysis-at-netflix-with-kayenta-3260bc7acc69)
- [Prometheus — Alerting Rules (for clause)](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
- [Sloth — Prometheus SLO Generator](https://github.com/slok/sloth)
