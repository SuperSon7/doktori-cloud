# Monitoring Config Reference

> 각 컴포넌트의 설정 값이 **왜** 그렇게 되어 있는지 정리한 문서.
> 설정을 바꿀 때 이 문서를 먼저 확인할 것.

---

## 1. 버전 선택 근거

| 컴포넌트 | 버전 | 선택 이유 |
|----------|------|----------|
| **Prometheus** | `v3.5.1` | 3.x부터 Native Histogram, UTF-8 metric name 지원. remote_write receiver 내장으로 Alloy push 수신에 별도 설정 불필요. 2.x → 3.x 마이그레이션 시 TSDB 포맷 호환 |
| **Loki** | `3.6.5` | 3.x부터 TSDB index 도입 (BoltDB 대비 쿼리 10배 빠름). schema v13 필수. 2.9.x에서 structured metadata, pattern ingester 미지원 |
| **Grafana** | `12.3.3` | Unified Alerting file-based provisioning 안정화 (11.x에서 일부 버그). 12.x에서 alert rule provisioning YAML 포맷 확정. 12.4.0은 출시 직후라 12.3.3 LTS 계열 유지 |
| **Alloy** | `v1.9.0` | Promtail + Node Exporter + mysqld_exporter 3개를 단일 바이너리로 대체. `env()` 함수 지원 (v1.5+)으로 플레이스홀더 sed 치환 불필요. Grafana 공식 후속 에이전트 |
| **Blackbox Exporter** | `latest` | 설정 없이 기본 `http_2xx` 모듈만 사용. 버전 간 breaking change 없는 안정된 도구 |
| **nginx-exporter** | `1.4` | Alloy에 nginx 내장 exporter 없어서 사이드카 유지. 8MB 이미지 + 32MB 메모리로 오버헤드 무시 가능 |

---

## 2. docker-compose.yml (모니터링 서버)

```yaml
# monitoring/docker-compose.yml
```

### Prometheus

| 설정 | 값 | 설명 |
|------|-----|------|
| `--storage.tsdb.path` | `/prometheus` | Docker volume에 TSDB 데이터 저장. 컨테이너 재시작해도 데이터 유지 |
| `--storage.tsdb.retention.time` | `30d` | 30일치 메트릭 보관. t4g.small 30GB 디스크 기준 ~5GB 예상 사용량 |
| `--web.enable-remote-write-receiver` | - | Alloy가 push하는 remote_write 엔드포인트(`/api/v1/write`) 활성화. 이거 없으면 Alloy → Prometheus 수신 불가 |
| `--web.enable-lifecycle` | - | `/-/reload` API 활성화. config 변경 시 재시작 없이 `curl -X POST localhost:9090/-/reload`로 반영 |

### Loki

| 설정 | 값 | 설명 |
|------|-----|------|
| `-config.file` | `/etc/loki/loki-config.yml` | 상세 설정은 아래 loki-config.yml 섹션 참조 |

### Grafana

| 설정 | 값 | 설명 |
|------|-----|------|
| `TZ` | `Asia/Seoul` | 알림 template의 `.Local.Format`이 KST로 출력되도록 설정. Grafana는 표시 계층이라 TZ 변경해도 데이터(Prometheus/Loki)에 영향 없음. 다른 컨테이너에는 넣지 말 것 |
| `GF_SECURITY_ADMIN_PASSWORD` | `${GF_ADMIN_PASSWORD:-admin}` | `.env`에서 주입. 미설정 시 `admin` (dev 전용, prod에서는 반드시 변경) |
| `GF_USERS_ALLOW_SIGN_UP` | `false` | 셀프 회원가입 비활성화. admin만 사용 |
| `GF_SERVER_ROOT_URL` | `${GRAFANA_ROOT_URL:-http://localhost:3000}` | 알림 메시지의 대시보드 링크 기준 URL. `.env`에 `GRAFANA_ROOT_URL` 설정. 미설정 시 localhost 폴백 |
| `DISCORD_*_WEBHOOK` | `.env`에서 주입 | Grafana가 provisioning YAML의 `${VAR}` 구문을 자동 resolve. **비어있으면 Grafana 기동 실패** |
| provisioning volume | `:ro` | read-only 마운트. Grafana가 provisioning 파일을 수정하지 못하게 강제 (Git이 single source of truth) |

### Volumes

| 볼륨 | 용도 |
|------|------|
| `prometheus_data` | TSDB 데이터. 삭제하면 30일치 메트릭 소실 |
| `loki_data` | 로그 chunks + index. 삭제하면 30일치 로그 소실 |
| `grafana_data` | 대시보드 상태, 알림 상태, 사용자 세션. 삭제해도 provisioning에서 복구됨 (단, alert state 초기화) |

### Network

- `monitoring` bridge: 모든 컨테이너가 서비스명으로 통신 (예: `prometheus:9090`, `loki:3100`)
- 외부 노출 포트: Prometheus 9090, Loki 3100, Grafana 3000, Blackbox 9115

---

## 3. prometheus.yml

```yaml
# monitoring/prometheus/prometheus.yml
```

| 설정 | 값 | 설명 |
|------|-----|------|
| `scrape_interval` | `15s` | 전역 수집 주기. Prometheus 권장 기본값. 너무 짧으면 TSDB 부하, 너무 길면 알림 지연 |
| `evaluation_interval` | `15s` | recording/alerting rule 평가 주기. scrape_interval과 동일하게 유지 |
| `rule_files` | `/etc/prometheus/rules/*.yml` | Prometheus 자체 recording rule용. 현재 비어있음 (알림은 Grafana Unified Alerting 사용) |

### scrape_configs

| job | 방식 | 설명 |
|-----|------|------|
| `prometheus` | Pull (self) | Prometheus 자체 메트릭 수집. `up`, `prometheus_tsdb_*` 등 |
| `blackbox-http` | Pull → Blackbox | 외부 URL 가용성 프로빙. 모니터링 서버에서 공개 URL로 HTTP 요청 |

### Blackbox relabel_configs 동작 원리

```
targets의 URL → __param_target (프로빙 대상)
__param_target → instance 라벨 (어떤 URL인지 식별)
__address__ → blackbox-exporter:9115 (실제 요청 대상을 Blackbox로 변경)
```

> Alloy가 push하는 메트릭(host, mysql, spring boot, nginx)은 scrape_configs에 없음.
> `--web.enable-remote-write-receiver`로 `/api/v1/write` 엔드포인트를 열어 수신.

---

## 4. loki-config.yml

```yaml
# monitoring/loki/loki-config.yml
```

| 섹션 | 설정 | 값 | 설명 |
|------|------|-----|------|
| **server** | `http_listen_port` | `3100` | Loki HTTP API 포트. Alloy가 여기로 push |
| | `grpc_listen_port` | `9096` | 내부 gRPC 통신용. 싱글 노드에서는 사용 안 하지만 기본값 유지 |
| **auth** | `auth_enabled` | `false` | 멀티테넌트 비활성화. 단일 팀 사용이므로 X-Scope-OrgID 헤더 불필요 |
| **limits** | `allow_structured_metadata` | `true` | Loki 3.x 기능. 로그 라인 외 구조화된 메타데이터 저장 허용 |
| | `volume_enabled` | `true` | `/loki/api/v1/index/volume` API 활성화. Grafana Logs 대시보드의 로그 볼륨 차트에 필요 |
| | `query_timeout` | `5m` | 긴 시간 범위 쿼리 허용. 기본 1m은 7일 범위 쿼리에 부족 |
| | `max_query_series` | `500` | 단일 쿼리가 반환하는 최대 시리즈 수. OOM 방지 |
| | `retention_period` | `30d` | Prometheus와 동일하게 30일 보관 |
| **common** | `kvstore.store` | `inmemory` | 싱글 노드이므로 분산 KV store 불필요. etcd/consul 의존성 제거 |
| | `replication_factor` | `1` | 싱글 노드. 복제 없음 |
| **schema** | `store` | `tsdb` | Loki 3.x 기본 인덱스 엔진. BoltDB 대비 쿼리 성능 10배 향상 |
| | `schema` | `v13` | TSDB store 사용 시 필수. v12 이하는 BoltDB용 |
| | `from` | `2026-02-17` | 이 스키마가 적용되는 시작일. 기존 데이터 마이그레이션 없이 새 스키마 적용 |
| **pattern_ingester** | `enabled` | `true` | 로그 패턴 자동 감지. Grafana에서 `pattern` 쿼리 함수 사용 가능 |
| **compactor** | `compaction_interval` | `10m` | 10분마다 chunk 압축. 디스크 사용량 절감 |
| | `retention_enabled` | `true` | retention_period 경과 데이터 자동 삭제. 이거 없으면 데이터 영구 보관 |
| | `retention_delete_delay` | `2h` | 삭제 마킹 후 2시간 뒤 실제 삭제. 실수로 삭제된 데이터 복구 여유 |

---

## 5. Grafana Provisioning

### datasources.yml

| 설정 | 값 | 설명 |
|------|-----|------|
| `uid` | `prometheus`, `loki` | alert-rules.yml의 `datasourceUid`와 매칭. 변경 시 alert rule도 같이 변경 필요 |
| `httpMethod` (Prometheus) | `POST` | 긴 PromQL 쿼리가 GET URL 길이 제한에 걸리지 않도록 POST 사용 |
| `manageAlerts` | `true` | 이 datasource에서 알림 규칙 생성 허용 |
| `editable` | `false` | UI에서 datasource 수정 불가. Git이 single source of truth |
| `prune` | `true` | 파일에 없는 datasource는 자동 삭제. 수동으로 추가한 datasource도 재시작 시 제거됨 |

### dashboards.yml

| 설정 | 값 | 설명 |
|------|-----|------|
| `updateIntervalSeconds` | `30` | 30초마다 대시보드 JSON 파일 변경 감지 |
| `allowUiUpdates` | `true` | UI에서 대시보드 수정 허용. 수정 후 JSON export → Git 반영 워크플로우 |
| `foldersFromFilesStructure` | `true` | 파일 시스템 디렉토리 구조 = Grafana 폴더 구조 |

---

## 6. Alloy config.alloy (Dev 서버)

```
# docker-compose.dev.yml의 alloy 서비스
```

### 환경변수

| 변수 | 용도 | 예시 |
|------|------|------|
| `MONITORING_IP` | 모니터링 서버 EIP. remote_write/loki push 대상 | `13.125.29.187` |
| `ALLOY_ENV` | 환경 구분 라벨 (`env`). 멀티 환경 메트릭 분리 | `dev`, `prod` |
| `MYSQL_DSN` | MySQL exporter 접속 정보 | `root:pass@(mysql:3306)/` |

### Volume 마운트

| 마운트 | 용도 |
|--------|------|
| `/host/proc`, `/host/sys`, `/host/root` | 호스트 메트릭 수집 (CPU, memory, disk). 컨테이너가 아닌 호스트 OS 지표 |
| `/var/run/docker.sock` | Docker 컨테이너 로그 수집. `loki.source.docker`가 소켓으로 로그 스트림 읽음 |

### 수집 대상

| 블록 | 대체하는 도구 | 수집 대상 | scrape_interval |
|------|-------------|----------|-----------------|
| `prometheus.exporter.unix` | node_exporter | CPU, memory, disk, network, loadavg | 15s |
| `prometheus.exporter.mysql` | mysqld_exporter | MySQL 커넥션, 쿼리, InnoDB | 15s |
| `prometheus.scrape "spring_boot"` | - | Spring Boot Actuator (API :8080, Chat :8081) | 15s |
| `prometheus.scrape "nginx"` | - | nginx-exporter :9113 (stub_status → Prometheus) | 15s |
| `loki.source.docker` | promtail | 컨테이너 stdout/stderr 로그 | 실시간 |

### 공통 라벨

```
env      = ALLOY_ENV 환경변수 (dev/prod)
instance = app 라벨 값 (api, chat, nginx) 또는 기존값 유지 (host, mysql exporter 주소)
job      = Alloy 내부 prefix 제거 (spring-boot, nginx, host, mysql)
```

> 모든 메트릭/로그에 `env`, `instance` 라벨 자동 부착 → 대시보드에서 환경별 필터링 가능
>
> instance 라벨은 `app` 라벨이 있는 경우(Spring Boot, Nginx) app 값으로 덮어씀.
> host metrics, MySQL은 `app` 라벨 없으므로 exporter 주소 유지.
>
> job 라벨은 `prometheus.scrape.` / `prometheus.exporter.` prefix와 `_metrics` 접미사 제거 후
> underscore를 hyphen으로 변환: `prometheus.scrape.spring_boot` → `spring-boot`

### 리소스 제한

| 항목 | 값 | 이유 |
|------|-----|------|
| `memory` | `256M` | dev 서버 t3.small (2GB RAM) 기준 전체 메모리의 12.5%. 과도한 사용 방지 |
| `cpus` | `0.25` | 수집 에이전트가 앱 성능에 영향 주지 않도록 제한 |
| `pid: host` | - | 호스트 PID namespace 공유. `process_*` 메트릭 수집에 필요 |

---

## 7. Alerting Provisioning

### contact-points.yml

| 설정 | 설명 |
|------|------|
| `uid` (receiver 레벨에만) | notification-policies에서 참조하는 식별자. contact point 레벨에 넣으면 Grafana 기동 실패 |
| `use_discord_username` | `true` — Grafana 봇 이름 대신 Discord webhook 이름 사용 |
| `disableResolveMessage` | `false` — 알림 해소 시 "Resolved" 메시지 자동 발송 |
| `${DISCORD_*_WEBHOOK}` | Grafana가 자체 환경변수로 resolve. docker-compose에서 주입 필수. **비어있으면 기동 실패** |

### notification-policies.yml

| 설정 | 값 | 설명 |
|------|-----|------|
| `group_by` | `[grafana_folder, alertname, app]` | 같은 폴더+같은 alert+같은 app을 하나의 그룹으로 묶어 발송. `app` 추가로 서비스별 개별 알림 (중복 `[FIRING:2]` 방지) |
| `group_wait` | severity별 다름 | 그룹 첫 알림 대기 시간. critical은 10s(즉시), info는 5m(묶어서) |
| `group_interval` | severity별 다름 | 그룹에 새 알림 추가 시 재발송 대기 |
| `repeat_interval` | severity별 다름 | 동일 알림 반복 발송 간격. critical 15분마다, info 12시간마다 |
| `continue: false` | - | 첫 매칭 route에서 멈춤. severity가 여러 route에 중복 매칭되지 않음 |

### alert-rules.yml

#### 공통 설정

| 설정 | 설명 |
|------|------|
| `condition: C` | refId C (threshold expression)의 결과로 발화 여부 결정 |
| `datasourceUid: __expr__` | Grafana 내장 expression 엔진. PromQL 결과를 threshold와 비교 |
| `relativeTimeRange.from: 300` | 최근 5분(300초) 데이터 조회 |
| `instant: true` | 범위 쿼리 대신 최신 값만 조회. 알림 평가에 range는 불필요 |

#### Threshold 선정 근거

| 룰 | Threshold | 근거 |
|----|-----------|------|
| `service_down` | `up == 0`, for 3m | Blue-Green 배포 전환에 2~3분 소요 → 배포 중 오발 방지. scrape_interval 15s 기준 12회 연속 실패 |
| `probe_failure` | `probe_success == 0`, for 5m | 배포 시 컨테이너 Recreate + Spring Boot 기동(~37초) + healthcheck 대기 = 최소 2~3분. 네트워크 불안정까지 고려해 5분 |
| `error_rate_critical` | `> 50%`, for 1m | 전체 요청의 절반 이상이 5xx → 서비스 사실상 사용 불가. 즉시 대응 필요 |
| `error_rate_high` | `> 10%`, for 3m | 10%는 유의미한 장애 신호. 3분 지속으로 일시적 배포 스파이크 무시 |
| `p99_high` | `> 5s`, for 3m | 5초는 사용자 이탈 임계점 (Google RAIL 모델). 3분으로 일시적 cold start 무시 |
| `hikari_pending` | `> 0`, for 2m | pending이 0 이상이면 커넥션 풀 고갈 시작. 2분으로 순간 burst 무시 |
| `gc_pause_high` | `> 500ms`, for 5m | 500ms GC pause는 요청 타임아웃 유발 가능. 5분으로 Major GC 단발 무시 |
| `memory_high` | `> 90%`, for 5m | 90%는 OOM killer 발동 직전 단계. 5분으로 일시적 캐시 사용 무시 |
| `cpu_high` | `> 80%`, for 5m | 80%는 여유분 20%만 남은 상태. 5분으로 배포/빌드 스파이크 무시 |
| `disk_critical` | `< 5%`, for 5m | 5% 미만은 로그 기록 불가 임계점. Docker overlay 포함 |
| `disk_warning` | `< 20%`, for 10m | 20%는 조치 여유 있는 사전 경고. 10분으로 대용량 파일 임시 생성 무시 |

#### `for` (pending 기간)

일시적 스파이크를 무시하기 위한 대기 시간:

| severity | `for` 범위 | 이유 |
|----------|-----------|------|
| critical | 3~5분 | 빠른 대응 필요하되 Blue-Green 배포 전환(2~3분) 중 오알림 방지 |
| high | 2~5분 | 영향 크지만 즉시 대응까진 불필요. 배포 직후 안정화 대기 |
| warning | 5~10분 | 사전 경고 성격. 충분히 지속될 때만 알림 |

#### `noDataState` / `execErrState` 설정

| 상태 | 적용 대상 | 설정 | 근거 |
|------|----------|------|------|
| `noDataState` | 전체 | `OK` | `up` 메트릭을 threshold(`< 1`)로 판단하는 방식이므로, 데이터가 없으면 Alerting 대신 OK로 처리. `up==0` 필터 방식에서는 정상 시 빈 결과 → noData 오발 문제가 있어 모든 룰을 OK로 통일 |
| `execErrState` | 전체 | `Alerting` | 쿼리 실행 에러 = Prometheus 연결 끊김 등 자체 장애 신호 |
| `execErrState` | `service_restarted` (info) | `OK` | 참고용 알림이므로 에러 시 무시 |

#### 노이즈 감소 전략

**1. `keep_firing_for: 10m` (flapping 방지)**

threshold 근처에서 진동하는 메트릭(memory, CPU, disk)에 적용. 조건 해소 후에도 10분간 firing 유지하여 알림-해소-알림 반복 방지.

적용 대상: `memory_high`, `cpu_high`, `disk_warning`, `disk_critical`

**2. Alert 의존성 (PromQL 인코딩)**

Grafana Built-in Alertmanager는 inhibition rule 미지원 → PromQL `and on(instance) up == 1`로 처리.

Application 룰들(`error_rate_high`, `p99_high`, `hikari_pending`, `gc_pause_high`)과 Infrastructure의 `error_rate_critical`에 적용:
- 호스트/서비스가 down이면 Application 알림 suppress
- 호스트 down + error rate critical + p99 high가 동시에 발생해도 service_down 하나만 알림

한계: PromQL 레벨 의존성은 `up` 메트릭 기준이므로 Alloy 자체가 죽으면 up 데이터도 없어짐 → noDataState: Alerting으로 보완

**3. `group_by: [grafana_folder, alertname, app]`**

같은 alertname이라도 서비스별(api, chat, nginx)로 그룹 분리 → `[FIRING:2]` 중복 알림 방지.
예: api와 chat 모두 error rate 초과 시 개별 알림 2건 발송 (하나의 묶음 알림이 아닌).

**4. 배포 중 알림 억제**

Blue-Green 배포 시 컨테이너 Recreate → MySQL healthcheck 대기 → Spring Boot 기동(~37초) → healthcheck 통과로 최소 2~3분 서비스 불가. 이 동안 Service Down, Probe Failure, Service Restarted, Error Rate 알림이 발생할 수 있음.

현재 적용된 대책:
- `service_down` for: 3m, `probe_failure` for: 5m으로 배포 시간보다 긴 대기
- Application 룰의 `and on(instance) up == 1` 조건으로 서비스 다운 중 평가 건너뜀

향후 도입 가능: Grafana Silence API 자동 연동, 배포 메트릭 조건 제외, SLO 기반 Multi-Window Burn Rate.
상세: `runbooks/operations/deploy-alert-suppression.md`

**5. Watchdog Alert**

`vector(1)` — 항상 firing. Discord `#alert-normal`에 12시간마다 반복 수신.
안 오면 모니터링 파이프라인(Prometheus → Grafana → Discord) 중 어딘가 장애.

### templates.yml

| 요소 | 설명 |
|------|------|
| `severity_emoji` | critical=🔴, high=🟠, warning=🟡, info=🔵. Discord 메시지에서 시각적 구분 |
| `.Status == "resolved"` | 해소 시 ✅ 이모지 + `EndsAt` 시각 표시 |
| `.StartsAt.Local.Format` | Go time format. KST 표시 (Grafana 컨테이너 `TZ=Asia/Seoul` 필수) |
| `dashboard_url`, `runbook_url` | annotations에 설정된 링크를 메시지에 포함. `GF_SERVER_ROOT_URL` 기반 절대 URL 생성 |

---

## 8. 향후 개선 로드맵

| 항목 | 설명 | 시기 |
|------|------|------|
| Grafana Silence API 연동 | 배포 스크립트에서 자동 Silence 생성/삭제. `deploy-prd.sh`에 통합 | 1순위 |
| 배포 메트릭 조건 제외 | `deployment_in_progress` 메트릭으로 알림 규칙 자체에서 배포 상태 인지 (Google SRE 방식) | Silence API 이후 |
| 이중 윈도우 burn-rate | error rate/latency를 SLO 기반으로 전환 (1h/5m). 배포 스파이크에 자연 면역 | 트래픽 안정화 후 |
| Prometheus recording rules | burn-rate 계산 사전 집계. 알림 평가 시 실시간 계산 부하 감소 | 이중 윈도우 도입 시 |
| Runbook 작성 + 링크 연결 | 각 알림별 대응 가이드 문서. annotations의 `runbook_url`에 연결 | Phase 4 전 |
| 외부 Alertmanager 전환 | inhibition rule 네이티브 지원. PromQL 의존성 인코딩 한계 극복 | 알림이 10개+ 될 때 |

> 배포 알림 억제 전략 상세: `runbooks/operations/deploy-alert-suppression.md`
> Prod 환경 마이그레이션 가이드: `runbooks/operations/alerting-prod-migration.md`

### 현재 한계점

1. **단일 윈도우 threshold**: 현재 모든 알림이 단일 시간 윈도우(5분) 기반. 장기간 서서히 악화되는 상황(slow degradation) 감지 불가
2. **PromQL 의존성**: `and on(instance) up == 1`은 `up` 메트릭 존재를 전제. Alloy 장애 시 up 데이터도 사라져 의존성 무력화
3. **정적 threshold**: 트래픽 패턴에 따라 정상 범위가 달라질 수 있으나 고정값 사용. 향후 SLO 기반으로 전환 필요
4. **Watchdog 한계**: Prometheus → Grafana 구간만 검증. Grafana → Discord webhook 구간은 별도 검증 필요
