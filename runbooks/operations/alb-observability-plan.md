# ALB 전환 시 옵저버빌리티 계획

Last updated: 2026-02-19
Author: jbdev

## 현재 구조 (Nginx)

```
Client → Nginx (EC2) → Backend containers
                ↓
         Alloy (같은 서버)
           ├─ loki.source.docker → Loki (로그)
           ├─ prometheus.scrape  → Prometheus (메트릭)
           └─ nginx-exporter     → Prometheus (nginx 메트릭)
```

**강점:** 단일 서버에서 Alloy가 모든 것을 수집, 구성 단순
**한계:** Nginx 자체가 SPOF, 스케일링 불가

## 전환 후 구조 (ALB)

```
Client → ALB → Target Group (EC2/ECS)
          ├─ ALB Access Log → S3
          ├─ CloudWatch Metrics
          └─ (WAF Log → S3, 선택)

Backend (EC2/ECS)
  └─ Alloy
       ├─ loki.source.docker → Loki (앱 로그)
       └─ prometheus.scrape  → Prometheus (앱/호스트 메트릭)

모니터링 서버
  ├─ Prometheus
  │    ├─ Alloy remote_write 수신 (기존 유지)
  │    ├─ CloudWatch Exporter (ALB 메트릭)
  │    └─ Blackbox Exporter (외부 프로빙, 기존 유지)
  ├─ Loki
  │    ├─ Alloy push (앱 로그, 기존 유지)
  │    └─ Promtail/Lambda (ALB access log from S3)
  └─ Grafana
```

## 변경되는 것 / 유지되는 것

| 항목 | Nginx 현재 | ALB 전환 후 |
|------|-----------|------------|
| 앱 로그 수집 | Alloy → Loki | **유지** (Alloy → Loki) |
| 앱 메트릭 수집 | Alloy → Prometheus | **유지** (Alloy → Prometheus) |
| 호스트 메트릭 | Alloy unix exporter | **유지** |
| 로드밸런서 메트릭 | nginx-exporter | **CloudWatch Exporter** |
| 로드밸런서 로그 | Alloy docker 수집 | **S3 → Loki 파이프라인** |
| 외부 프로빙 | Blackbox Exporter | **유지** |
| SSL 인증서 | Let's Encrypt + certbot | **ACM (AWS 관리)** |

## 단계별 전환 계획

### Phase 1: ALB 메트릭 수집 (CloudWatch → Prometheus)

모니터링 서버에 CloudWatch Exporter(YACE) 추가.

```yaml
# docker-compose.monitoring.yml에 추가
yace:
  image: ghcr.io/nerdswords/yet-another-cloudwatch-exporter:v0.62.0
  volumes:
    - ./yace/config.yml:/tmp/config.yml:ro
  environment:
    - AWS_REGION=ap-northeast-2
```

수집할 ALB 메트릭:

| CloudWatch 메트릭 | 용도 |
|-------------------|------|
| `RequestCount` | 트래픽량 |
| `TargetResponseTime` | 백엔드 응답 시간 (p50/p95/p99) |
| `HTTPCode_ELB_5XX_Count` | ALB 자체 에러 |
| `HTTPCode_Target_5XX_Count` | 백엔드 5xx |
| `HealthyHostCount` | 정상 타겟 수 |
| `UnhealthyHostCount` | 비정상 타겟 수 |
| `ActiveConnectionCount` | 동시 연결 수 |

→ nginx_up, nginx_connections 등을 대체

### Phase 2: ALB Access Log → Loki

ALB access log를 S3에 저장하고 Loki로 수집.

**Option A: Lambda → Loki push (추천)**
```
ALB → S3 (5분 단위) → S3 Event → Lambda → Loki API push
```
- 장점: 서버리스, 관리 부담 없음
- 단점: 5분 지연 (ALB 로그 특성)

**Option B: Promtail S3 discovery**
```
ALB → S3 → Promtail (모니터링 서버) → Loki
```
- 장점: 기존 인프라 활용
- 단점: Promtail이 S3 polling, 리소스 사용

**필요 인프라:**
- S3 버킷 (ALB access log 전용, Terraform으로 생성)
- 버킷 lifecycle: 30일 후 삭제 (Loki에 이미 보관)
- ALB에서 access log 활성화

### Phase 3: 대시보드 마이그레이션

| 현재 (Nginx) | 전환 후 (ALB) |
|-------------|--------------|
| `nginx_http_requests_total` | `aws_alb_request_count_sum` |
| `nginx_up` | `aws_alb_healthy_host_count` |
| nginx access log `rt=` | `aws_alb_target_response_time` (p50/p95/p99) |
| nginx error log `upstream` | `aws_alb_httpcode_target_5xx_count_sum` |
| nginx access log 5xx | `aws_alb_httpcode_elb_5xx_count_sum` |

### Phase 4: 제거

- nginx 서비스 및 nginx-exporter 제거
- config.alloy에서 nginx scrape 블록 제거
- stub_status 설정 제거

## 주의사항

1. **ALB access log는 실시간이 아님** — 5분 단위 S3 저장. 실시간 장애 감지는 CloudWatch 메트릭 + 알람으로 처리
2. **Client IP** — ALB가 `X-Forwarded-For` 헤더 추가, 백엔드 앱 로그에서 확인 가능. Spring Boot에서 `server.forward-headers-strategy=native` 설정 필요
3. **비용** — ALB access log S3 저장 비용 + CloudWatch API 호출 비용. YACE scrape interval을 60s 이상으로 설정하여 API 비용 최소화
4. **Alloy는 유지** — ALB 전환해도 백엔드 앱 로그/메트릭 수집은 Alloy가 계속 담당. 로드밸런서 레이어만 변경됨

## 관련 문서

- [log-reliability.md](log-reliability.md) — 로그 신뢰성 가이드 (Prod WAL/S3 계획 포함)
- [TODO-deploy.md](../../monitoring/alloy/TODO-deploy.md) — Alloy 배포 체크리스트
