# Observability Upgrade Roadmap

> 최종 목표: 서비스 전체에 대한 **메트릭 수집 → 시각화 → 알림 → 자동 분석** 파이프라인 구축
>
> 트래킹 시작: 2026-02-18

---

## 진행 현황

| Phase | 제목 | 상태 | 완료일 | 비고 |
|:-----:|------|:----:|:-----:|------|
| 0 | [Migration](#phase-0-migration) | ✅ Done | 2026-02-18 | Docker Compose 스택 |
| 1 | [Alloy 전환](#phase-1-alloy-전환) | ✅ Done | 2026-02-18 | 단일 에이전트 수집 |
| 2 | [대시보드 체계화](#phase-2-대시보드-체계화) | ✅ Done | 2026-02-18 | 5개 대시보드 신규 |
| 3 | [알림 체계 구축](#phase-3-알림-체계-구축) | ✅ Done | 2026-02-19 | Grafana Unified Alerting |
| 4 | [AI 장애 분석](#phase-4-ai-장애-분석) | 🔲 Todo | - | LLM 자동 분석 |
| 5 | [Tracing + ChatOps](#phase-5-tracing--chatops) | 🔲 Todo | - | Tempo + Discord Bot |

---

## Phase 0: Migration

**목표:** 구 계정 → 신 계정 이관, Docker Compose 기반 모니터링 서버 구축

### Checklist
- [x] Terraform으로 monitoring EC2 생성 (t4g.small, EIP, SG WireGuard only)
- [x] Docker Compose 스택 구성 (Prometheus, Loki, Grafana)
- [x] Prometheus config 마이그레이션 (Jinja2 → static, target IP 업데이트, retention 설정)
- [x] Loki 업그레이드 v2.9.4 → v3.4+ (schema v13, tsdb index, Docker volume)
- [x] Grafana 대시보드 JSON export + provisioning 설정
- [x] 전체 Prometheus target UP 확인, Loki 로그 수신 확인

### 산출물
- `Cloud/monitoring/docker-compose.yml`
- `Cloud/monitoring/prometheus/`, `Cloud/monitoring/loki/`, `Cloud/monitoring/grafana/`

---

## Phase 1: Alloy 전환

**목표:** Promtail + Node Exporter → Grafana Alloy 단일 에이전트로 통합

### Checklist
- [x] Alloy config 작성
  - [x] `prometheus.exporter.unix` (Node Exporter 대체)
  - [x] Spring Boot Actuator scrape (API :8080, Chat :8081)
  - [x] nginx exporter scrape
  - [x] Spring Boot log → `loki.source.file` (Promtail 대체)
  - [x] nginx access/error log 수집 (신규)
- [x] dev 환경 배포 및 데이터 패리티 검증
- [x] 기존 Node Exporter, Promtail 서비스 제거

### 산출물
- `Cloud/monitoring/alloy/config.alloy`
- 배포 런북: `Cloud/runbooks/deployment/monitoring-deploy.md`

---

## Phase 2: 대시보드 체계화

**목표:** 의사결정에 쓸 수 있는 대시보드 구축

### Checklist
- [x] Overview 대시보드 — 서비스 UP/DOWN, error rate, request volume
- [x] JVM-API 대시보드 — Heap, GC, Thread, HikariCP (DoktoriHikariPool)
- [x] JVM-Chat 대시보드 — 동일 구조, ChatHikariPool, Tomcat max=100
- [x] HTTP RED 대시보드 — Rate/Error/Duration, per-endpoint p50/p95/p99
- [x] Logs 대시보드 — Loki 기반 에러 스트림, 볼륨 트렌드
- [x] Chat 서비스 histogram 활성화 (`percentiles-histogram: true`)
- [x] 기존 Nginx, System 대시보드 확인 (이미 충분)

### 산출물
- `Cloud/monitoring/grafana/dashboards/overview.json`
- `Cloud/monitoring/grafana/dashboards/jvm-api.json`
- `Cloud/monitoring/grafana/dashboards/jvm-chat.json`
- `Cloud/monitoring/grafana/dashboards/http-red.json`
- `Cloud/monitoring/grafana/dashboards/logs.json`
- `Backend/chat/src/main/resources/application.yml` (histogram 설정)

### 관련 커밋
- Backend `700eab5` feat(chat): enable HTTP request histogram metrics
- Cloud `9c18952` feat(grafana): add Phase 2 dashboards (overview, jvm, http-red, logs)

---

## Phase 3: 알림 체계 구축

**목표:** Severity 기반 알림 + Discord 채널 분리 + Runbook 연결

### Severity 정의

| Level | 이름 | 대응 시간 | Discord 채널 | 예시 |
|:-----:|------|----------|-------------|------|
| P1 | Critical | 15분 이내 | `#alert-critical` (@here) | 서비스 다운, 5xx > 50%, disk > 95% |
| P2 | High | 1시간 이내 | `#alert-high` | p99 > 5s, error rate > 10%, memory > 90% |
| P3 | Warning | 업무 시간 내 | `#alert-warning` | CPU > 80% 지속, disk > 80%, GC pause 증가 |
| P4 | Info | 다음 업무일 | `#alert-info` | 배포 완료, 인증서 30일 전 만료, 주간 리포트 |

### Checklist
- [x] Discord webhook 생성 (2채널: `#alert-urgent`, `#alert-normal`)
- [x] Grafana Contact Points 설정 (4개 Discord webhook → 2채널로 매핑)
- [x] Notification Policy 설정 (severity label 기반 라우팅)
- [x] Alert Rules 작성
  - [x] P1: `up == 0`, `probe_success == 0`, error rate > 50%, disk > 95%
  - [x] P2: p99 > 5s, error rate > 10%, memory > 90%, HikariCP pending > 0
  - [x] P3: CPU > 80% 5분, disk > 80%, GC pause > 500ms
  - [x] P4: 서비스 재시작 감지
- [x] 커스텀 메시지 템플릿 작성 (severity별 이모지, dashboard/runbook 링크 포함)
- [x] Alert rule provisioning YAML 작성 (Git 관리, file-based provisioning)
- [x] 테스트: Discord 알림 발송 확인

### 산출물
- `Cloud/monitoring/grafana/provisioning/alerting/contact-points.yml`
- `Cloud/monitoring/grafana/provisioning/alerting/notification-policies.yml`
- `Cloud/monitoring/grafana/provisioning/alerting/alert-rules.yml`
- `Cloud/monitoring/grafana/provisioning/alerting/templates.yml`
- Discord 2채널 (urgent: critical+high, normal: warning+info)

### 관련 커밋
- Cloud `05d59b1` feat(alerting): add Grafana alerting provisioning (Phase 3)

---

## Phase 4: AI 장애 분석

**목표:** P1/P2 알림 발생 시 LLM이 자동으로 근본 원인 분석

### 흐름
```
P1/P2 Alert → Grafana Webhook → 분석 서비스 → Loki/Prometheus 쿼리
→ LLM API (Claude/GPT) → Discord에 분석 결과 전송
```

### Checklist
- [ ] 분석 서비스 구현 (Python FastAPI)
  - [ ] Loki API로 에러 로그 조회 (alert 전후 5분)
  - [ ] Prometheus API로 핵심 메트릭 조회 (CPU, memory, HTTP, JVM)
  - [ ] LLM API 호출 → 근본 원인 예측, 영향 범위, 권장 조치
- [ ] 서비스-담당자 매핑 테이블 (JSON/YAML)
- [ ] Discord 알림 포맷: 사고 요약 + 대시보드 링크 + 권장 조치 + 담당자 멘션
- [ ] P1/P2만 LLM 호출 (비용 관리)
- [ ] Docker Compose에 분석 서비스 추가

### 산출물 (예상)
- `Cloud/monitoring/incident-analyzer/` (FastAPI 앱)
- service-owner 매핑 config

---

## Phase 5: Tracing + ChatOps

**목표:** 분산 추적 + Discord Bot으로 운영 편의성 확보 (학습 목적)

### Tracing (Tempo)
- [ ] Docker Compose에 Grafana Tempo 추가
- [ ] Spring Boot에 Micrometer Tracing + OTLP exporter 추가
- [ ] Alloy에 `otelcol.receiver.otlp` → Tempo forward 설정
- [ ] Grafana에서 log ↔ trace ↔ metric 상관관계 (Exemplars) 설정

### ChatOps (Discord Bot)
- [ ] `/status` — 서비스 상태 조회
- [ ] `/ack <alert>` — 알림 확인 처리
- [ ] `/silence <rule> <duration>` — 알림 일시 중지
- [ ] `/dashboard <name>` — 대시보드 스크린샷 반환
- [ ] Grafana HTTP API + Discord.py 구현

### 산출물 (예상)
- Tempo config + Spring Boot tracing 설정
- Discord Bot 서비스

---

## 기술 스택 변경 요약

| 구성 요소 | AS-IS | TO-BE |
|----------|-------|-------|
| 배포 | Ansible + binary + systemd | **Docker Compose** ✅ |
| 에이전트 | Promtail 2.9.4 + Node Exporter 1.6.1 | **Grafana Alloy** ✅ |
| 메트릭 저장 | Prometheus 2.45.0 | **Prometheus 2.55+** ✅ |
| 로그 저장 | Loki 2.9.4 (schema v11) | **Loki 3.4+** (schema v13) ✅ |
| 시각화 | Grafana (apt) | **Grafana 11.5+** (Docker) ✅ |
| 알림 | CPU/mem → Discord (severity 없음) | **Grafana Unified Alerting** (4단계) |
| 로그 수집 | Spring Boot 로그만 | Spring Boot + **nginx + container** ✅ |
| 보안 | 포트 오픈 (0.0.0.0/0) | **VPN 뒤** (WireGuard) ✅ |
| 추적 | 없음 | (Phase 5) Tempo + OpenTelemetry |
| AI 분석 | 없음 | (Phase 4) LLM 자동 장애 분석 |
