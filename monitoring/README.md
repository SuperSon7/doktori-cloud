# Monitoring & IP Change Guide

이 문서는 모니터링 스택 구성 요소 버전과, prod/dev/monitoring 서버의 IP, 도메인, 접근 CIDR이 변경될 때 어떤 파일을 확인/수정해야 하는지 정리한 가이드입니다.

---

## 모니터링 스택 버전 (2026-03-19 기준)

### 모니터링 서버 (Docker Compose)

| 컴포넌트 | 버전 | 용도 |
|----------|------|------|
| Prometheus | v3.5.1 | 메트릭 저장 + 알림 평가 |
| Grafana | 12.3.3 | 대시보드 + 알림 라우팅 |
| Loki | 3.6.5 | 로그 저장 (structured metadata 지원) |
| Blackbox Exporter | latest | 외부 엔드포인트 프로빙 |
| cAdvisor | latest | 모니터링 서버 컨테이너 리소스 |

### K8s 클러스터 (DaemonSet / Deployment)

| 컴포넌트 | 버전 | 용도 |
|----------|------|------|
| Grafana Alloy | v1.9.0 | 메트릭 수집 + 로그 수집 → 모니터링 서버로 push |
| kube-state-metrics | v2.15.0 (Helm 5.28.1) | K8s 오브젝트 상태 메트릭 |
| metrics-server | v0.7.2 (Helm 3.12.2) | HPA용 리소스 메트릭 |

### 주요 설정 참고

- Loki `limits_config.allow_structured_metadata: true` — traceId를 structured metadata로 저장
- Alloy에서 `component` → `app` relabel 매핑 — 기존 대시보드/알림 호환
- Prometheus `--web.enable-remote-write-receiver` — Alloy remote_write 수신

---

## 핵심 변경 포인트

### 1. Prometheus 스크랩 대상 (가장 중요)

- **파일**
  - `monitoring/prometheus/prometheus.yml`

- **변경 대상**
  - `node_exporter` 타깃 IP: `52.79.205.195:9100`, `3.37.180.158:9100`
  - `spring-boot-prod` 타깃 도메인: `doktori.kr`
  - `spring-boot-dev` 타깃 도메인: `dev.doktori.kr`
  - `mysql-prod` 타깃 IP: `3.37.180.158:9104`
  - `blackbox` HTTP 체크 대상: `https://doktori.kr`

- **의미**
  - 서버 IP/도메인 변경 시 여기의 `targets`를 반드시 갱신해야 합니다.

---

### 2. 모니터링 서버 접근 IP (보안그룹 변수)

- **파일**
  - `terraform/variables.tf`

- **변경 대상**
  - `monitoring_server_ip` 기본값: `43.201.9.63/32`
  - `allowed_admin_cidrs` 기본값: `["211.244.225.166/32", "211.244.225.211/32"]`

- **의미**
  - 모니터링 서버 IP가 바뀌면 `monitoring_server_ip` 값을 갱신해야 `9100` 접근이 열립니다.

---

### 3. 보안그룹 고정 IP 하드코딩

- **파일**
  - `terraform/security_groups.tf`

- **변경 대상**
  - Grafana 접근: `122.40.177.81/32`
  - AI Service (8001) 접근: `211.244.225.166/32`
  - Loki/Promtail 접근: `211.244.225.166/32`

- **의미**
  - 운영/모니터링 접근 IP 변경 시 이 부분도 함께 갱신해야 합니다.

---

### 4. 인프라에서 실제 서버 IP 확인

- **파일**
  - `terraform/outputs.tf`

- **확인 대상**
  - `instance_public_ip`, `instance_public_dns`

- **의미**
  - 실제 서버 IP 변경 시 여기 output을 확인하고 `monitoring/prometheus/prometheus.yml`에 반영합니다.

---

### 5. 환경(dev/prod) 기본 변수

- **파일**
  - `terraform/variables.tf`

- **확인 대상**
  - `environment` 기본값: `dev`

- **의미**
  - 배포 시점에 어떤 환경 값을 쓰는지 확인이 필요합니다. (repo 내 tfvars 없음)

---

## 변경 시 체크리스트

- 서버 IP/도메인 변경 시  
  → `monitoring/prometheus/prometheus.yml`

- 모니터링 서버 IP 변경 시  
  → `terraform/variables.tf` + `terraform/security_groups.tf`

- 접근 허용 CIDR 변경 시  
  → `terraform/variables.tf` + `terraform/security_groups.tf`

- 현재 인프라 IP 확인  
  → `terraform/outputs.tf`

---
