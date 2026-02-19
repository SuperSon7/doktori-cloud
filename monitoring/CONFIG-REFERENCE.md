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
| `GF_SERVER_ROOT_URL` | `http://localhost:3000` | 알림 메시지의 대시보드 링크 기준 URL. prod에서는 실제 도메인으로 변경 필요 |
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
instance = constants.hostname (호스트명)
```

> 모든 메트릭/로그에 `env`, `instance` 라벨 자동 부착 → 대시보드에서 환경별 필터링 가능

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
| `group_by` | `[grafana_folder, alertname]` | 같은 폴더+같은 alert를 하나의 그룹으로 묶어 알림 발송. 개별 instance마다 보내지 않음 |
| `group_wait` | severity별 다름 | 그룹 첫 알림 대기 시간. critical은 10s(즉시), info는 5m(묶어서) |
| `group_interval` | severity별 다름 | 그룹에 새 알림 추가 시 재발송 대기 |
| `repeat_interval` | severity별 다름 | 동일 알림 반복 발송 간격. critical 15분마다, info 12시간마다 |
| `continue: false` | - | 첫 매칭 route에서 멈춤. severity가 여러 route에 중복 매칭되지 않음 |

### alert-rules.yml

| 설정 | 설명 |
|------|------|
| `condition: C` | refId C (threshold expression)의 결과로 발화 여부 결정 |
| `datasourceUid: __expr__` | Grafana 내장 expression 엔진. PromQL 결과를 threshold와 비교 |
| `relativeTimeRange.from: 300` | 최근 5분(300초) 데이터 조회 |
| `instant: true` | 범위 쿼리 대신 최신 값만 조회. 알림 평가에 range는 불필요 |
| `for` | 이 시간 동안 조건 지속 시 발화. 일시적 스파이크 무시. critical은 1~2분, warning은 5~10분 |
| `noDataState: OK` | 데이터 없을 때 OK 처리. 서비스가 아직 시작 안 했거나 메트릭이 없는 경우 오알림 방지 |
| `execErrState: Alerting` | 쿼리 실행 에러 시 Alerting. Prometheus 연결 끊김 등 자체가 장애 신호 |

### templates.yml

| 요소 | 설명 |
|------|------|
| `severity_emoji` | critical=🔴, high=🟠, warning=🟡, info=🔵. Discord 메시지에서 시각적 구분 |
| `.Status == "resolved"` | 해소 시 ✅ 이모지 + `EndsAt` 시각 표시 |
| `.StartsAt.Local.Format` | Go time format. KST 표시 |
| `dashboard_url`, `runbook_url` | annotations에 설정된 링크를 메시지에 포함. 알림 → 대시보드 원클릭 이동 |
