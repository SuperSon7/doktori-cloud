# 알림 체계 Prod 환경 적용 가이드

Dev에서 검증된 알림 설정을 Prod에 적용하는 절차.

---

## 파일 구조

```
Cloud/monitoring/grafana/provisioning/alerting/
├── alert-rules.yml           # 환경 무관 — 그대로 복사
├── notification-policies.yml  # 환경 무관 — 그대로 복사
├── templates.yml              # 환경 무관 — 그대로 복사
└── contact-points.yml         # 환경변수로 분리됨 — 그대로 복사
```

**모든 파일이 환경에 종속되지 않음.** PromQL은 범용 메트릭(`up`, `probe_success`, `node_*`)만 사용.

---

## 환경별로 달라지는 것

### 1. Discord Webhook URL (`.env`)

```bash
# dev 환경 .env
DISCORD_CRITICAL_WEBHOOK=https://discord.com/api/webhooks/dev-critical/...
DISCORD_HIGH_WEBHOOK=https://discord.com/api/webhooks/dev-high/...
DISCORD_WARNING_WEBHOOK=https://discord.com/api/webhooks/dev-warning/...
DISCORD_INFO_WEBHOOK=https://discord.com/api/webhooks/dev-info/...

# prod 환경 .env — 채널만 다름
DISCORD_CRITICAL_WEBHOOK=https://discord.com/api/webhooks/prod-critical/...
DISCORD_HIGH_WEBHOOK=https://discord.com/api/webhooks/prod-high/...
DISCORD_WARNING_WEBHOOK=https://discord.com/api/webhooks/prod-warning/...
DISCORD_INFO_WEBHOOK=https://discord.com/api/webhooks/prod-info/...
```

`contact-points.yml`에서 `${DISCORD_*_WEBHOOK}` 변수를 참조하므로 파일 수정 불필요.

### 2. Grafana Root URL (`.env`)

```bash
# dev
GRAFANA_ROOT_URL=http://13.125.29.187:3000

# prod
GRAFANA_ROOT_URL=https://grafana.doktori.kr  # 또는 prod 모니터링 서버 주소
```

대시보드 링크가 알림에 포함될 때 사용.

### 3. Blackbox Exporter 타겟

Prometheus의 `prometheus.yml`에서 프로브 대상이 다름:

```yaml
# dev
- targets:
    - https://dev.doktori.kr/api/actuator/health

# prod
- targets:
    - https://doktori.kr/api/actuator/health
    - https://doktori.kr/api/health  # 필요 시 추가
```

---

## 적용 절차

### Step 1: Prod 모니터링 서버 준비

```bash
# prod 모니터링 서버에 디렉토리 생성
ssh -i ~/.ssh/doktori-prod.pem ubuntu@<PROD_MONITORING_IP> \
  "mkdir -p ~/monitoring/grafana/provisioning/alerting"
```

### Step 2: 파일 복사

```bash
# 알림 설정 4개 파일 복사
scp -i ~/.ssh/doktori-prod.pem \
  Cloud/monitoring/grafana/provisioning/alerting/*.yml \
  ubuntu@<PROD_MONITORING_IP>:~/monitoring/grafana/provisioning/alerting/
```

### Step 3: .env 설정

```bash
# prod 모니터링 서버에서
vi ~/monitoring/.env

# 최소 필수 항목:
DISCORD_CRITICAL_WEBHOOK=<prod용 webhook>
DISCORD_HIGH_WEBHOOK=<prod용 webhook>
DISCORD_WARNING_WEBHOOK=<prod용 webhook>
DISCORD_INFO_WEBHOOK=<prod용 webhook>
GRAFANA_ROOT_URL=<prod Grafana URL>
```

### Step 4: Grafana 재시작

```bash
ssh -i ~/.ssh/doktori-prod.pem ubuntu@<PROD_MONITORING_IP> \
  "docker restart grafana"
```

### Step 5: 검증

`Cloud/runbooks/operations/alerting-verification.md` 참고.

```bash
# Grafana 로그 확인
docker logs grafana --tail 20 2>&1 | grep -E 'provisioning|error|panic'

# Alert rules 로드 확인
# Grafana UI → Alerting → Alert rules → 3개 폴더 확인

# Discord 테스트
# Alerting → Contact points → 각 채널 Test 버튼
```

---

## Prod에서 고려할 threshold 조정

| 룰 | Dev | Prod 권장 | 이유 |
|---|---|---|---|
| `service_down` for | 3m | 3m | BG 배포 전환 2~3분 커버 |
| `probe_failure` for | 5m | 5m | 배포 중 오발 방지 |
| `error_rate_critical` for | 1m | 2m | prod 트래픽이 많으면 순간 스파이크 가능 |
| `disk_critical` for | 5m | 5m | 유지 |
| `memory_high` for | 5m | 10m | prod에서 메모리 변동 더 클 수 있음 |
| `cpu_high` for | 5m | 10m | 배포/배치 작업 시 CPU 스파이크 |
| critical repeat_interval | 15m | 15m | 유지 |
| high repeat_interval | 1h | 1h | 유지 |

> Dev와 동일하게 시작하고, 오발이 발생하면 `for` 값을 조정.

---

## 배포 알림 억제 (Grafana Silence API)

`deploy-prd.sh`에 이미 Silence API 연동 코드가 포함되어 있음. 환경변수만 설정하면 활성화됨.

### Step 1: Grafana Service Account 토큰 발급

prod 모니터링 서버 Grafana UI에서:

1. **Administration** → **Service accounts** → **Add service account**
2. Display name: `deploy-silence`, Role: **Editor**
3. 생성된 account → **Add service account token** → **Generate token**
4. `glsa_xxxxxxxx...` 형태 토큰 복사

### Step 2: prod 앱 서버에 환경변수 설정

```bash
# /etc/environment 에 추가 (재부팅 후에도 유지)
GRAFANA_URL=http://<PROD_MONITORING_PRIVATE_IP>:3000
GRAFANA_SA_TOKEN=glsa_복사한토큰값
```

> Private IP 사용 — VPC 내부 통신. 모니터링 서버에서 `hostname -I`로 확인.

### Step 3: jq 설치 확인

```bash
which jq || sudo apt-get install -y jq
```

### 동작 확인

환경변수 설정 후 다음 배포 시 로그에서 확인:
```
🔇 Silence created: abc-123-... (10분 자동 만료)
...
🔔 Silence deleted: abc-123-...
```

미설정 시에는 `⚠️ GRAFANA_URL/GRAFANA_SA_TOKEN 미설정 — Silence 건너뜀`이 출력되고 기존과 동일하게 배포 진행.

> 상세 전략: `deploy-alert-suppression.md` 참고

---

## Prod/Dev 채널 분리 전략

### 옵션 A: 완전 분리 (권장)

```
Discord 서버
├── #alert-prod-urgent   ← prod critical + high
├── #alert-prod-normal   ← prod warning + info
├── #alert-dev-urgent    ← dev critical + high
└── #alert-dev-normal    ← dev warning + info
```

각 환경의 `.env`에 다른 webhook URL 설정.

### 옵션 B: 통합 + 라벨 구분

하나의 채널에서 환경 라벨로 구분. **비권장** — prod 알림이 dev 알림에 묻힘.

---

## 체크리스트

- [ ] Prod Discord 채널 생성 + webhook URL 발급
- [ ] Prod 모니터링 서버에 alerting 파일 4개 복사
- [ ] `.env`에 webhook URL + GRAFANA_ROOT_URL 설정
- [ ] Prometheus `prometheus.yml`에 prod blackbox 타겟 설정
- [ ] Grafana 재시작 + provisioning 로그 확인
- [ ] Alert rules 3개 폴더 로드 확인
- [ ] Contact points Test 버튼으로 Discord 수신 확인
- [ ] Watchdog 알림 수신 확인 (12시간 내)
- [ ] Grafana Service Account 토큰 발급 (Editor role)
- [ ] Prod 앱 서버에 `GRAFANA_URL` + `GRAFANA_SA_TOKEN` 환경변수 설정
- [ ] Prod 앱 서버에 `jq` 설치 확인
