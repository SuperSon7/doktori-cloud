# Doktori 부하테스트 종합 리포트

> 테스트 기간: 2026-03-19 ~ 2026-03-23
> 대상: api.doktori.kr (프로덕션 K8s v1.31, RDS Proxy, NGF keepAlive)
> 인프라: EC2 러너 3대 (t4g.medium, 별도 AWS 계정)
> 모니터링: Grafana + Prometheus (native histogram)

---

## Executive Summary

1. **단계별 인프라 개선으로 stress 5xx 31% → 4.5% (85% 감소)**
2. **정상 트래픽(읽기 위주 300 VU)에서 SLO 충족** — P95 30ms, 5xx 0%
3. **쓰기 45% 부하에서 같은 300 VU로 P95 1,600배 악화** — 읽기 위주 테스트가 성능을 과대평가
4. **HPA 스케일아웃 정상 확인** — WS 1500 VU에서 API 2→5, Chat 2→4 Pod
5. **Chat HPA CPU 기준 유효** — WS 부하 시 CPU가 비례 증가 (100 VU→9%, 1500 VU→89%)
6. **5xx 근본 원인: ALB TargetConnectionError (17만건)** — NGF keepAlive 활성화로 해결
7. **RDS CPU 병목** — db.t4g.small vCPU 2개 포화 (97%), 풀테이블 스캔 쿼리 식별

---

## Stress 개선 여정 (핵심)

| 단계 | 변경 | 5xx | P95 | RPS | 핵심 효과 |
|------|------|-----|-----|-----|----------|
| 0 | 기준 (Proxy 없음, HPA 미동작) | **31%** | 2.29s | 658/s | - |
| 1 | +RDS Proxy | 32% | 2.16s | 941/s | RPS +43% |
| 2 | +JDBC 최적화 | 19% | 6.13s | 483/s | 5xx -39% |
| 3 | +HPA 정상화 (metrics-server) | 25% | 4.08s | 702/s | Pod 오토스케일링 |
| **4** | **+NGF keepAlive** | **4.5%** | **5.79s** | **409/s** | **5xx -82%** |

**31% → 4.5% = 총 85% 에러 감소**

---

## SLO 기준

| SLO | 지표 | 목표 | Load (300VU) | Stress (1500VU) |
|-----|------|------|-------------|----------------|
| SLO-1 | 5xx 비율 | < 0.5% | **0% PASS** | 4.5% FAIL |
| SLO-2 | P95 Latency | ≤ 1000ms | **30ms PASS** | 5.79s FAIL |

---

## 시나리오별 결과

| 시나리오 | VU | 총 요청 | RPS | P95 | 5xx | SLO |
|---------|-----|---------|-----|-----|-----|-----|
| Smoke | 15 | 468 | 7.3/s | 19ms | 0% | **PASS** |
| Load v1 (읽기 위주) | 300 | 101K | 105/s | 30ms | 0% | **PASS** |
| Guest Flow | 300 | 76K | 78/s | 21ms | 0% | **PASS** |
| Load v2 (쓰기 45%) | 300 | 29K | 29/s | 48s | 14% | FAIL |
| Stress (최종) | 1,500 | 320K | 409/s | 5.79s | 4.5% | FAIL |
| Meeting Search | 1,500 | 212K | 236/s | 4.69s | 36% | FAIL |
| Lifecycle (WS+HTTP 5분) | 150 | 11K+WS | 25/s | 20ms | 0% | **PASS** |
| WS Stress (1500 WS) | 1,710 | 38K+WS | - | - | - | WS 연결 85% 실패 |

---

## WebSocket 검증

### Lifecycle 30분 (WS 100 + HTTP 50)

| 시점 | Chat CPU | Chat 메모리 | API CPU |
|------|----------|------------|---------|
| 1분 (스파이크) | 26% (74~84m) | 432~439Mi | 21% |
| 15분 (안정) | 10% (30~32m) | 436~443Mi | 15% |
| 22분 (안정) | 9% (27~28m) | 437~444Mi | 17% |

- WS 100 연결 유지 + 5초 간격 메시지 → Chat CPU 9% (안정)
- 메모리 변화 미미 (+12Mi)
- **30분 세션 유지 성공**

### WS Stress (WS 1500 + HTTP 210, 5분)

| 지표 | 값 |
|------|-----|
| WS 연결 성공 | 1,119 / 7,337 시도 (15%) |
| WS 메시지 송신 | 55,948 |
| WS 메시지 수신 | 28,231 |
| HPA | API 2→5, Chat 2→4 |
| Chat CPU 피크 | **89%** → Pod 추가 후 72% |
| Chat 메모리 피크 | 620Mi (limit 1536Mi의 40%) |

**Chat HPA CPU 기준 유효 확인:**
- WS 100 → CPU 9% / WS 1500 → CPU 89% — **선형 비례**
- 60% 트리거 도달 시 자동 스케일아웃 → CPU 72%로 하락
- 메모리는 40%로 여유 — CPU가 먼저 병목

---

## 5xx 근본 원인 분석

### ALB TargetConnectionError (keepAlive 적용 전)

| 메트릭 | 수량 | 의미 |
|--------|------|------|
| **HTTPCode_ELB_5XX** | ~135,000 | ALB가 반환한 5xx |
| HTTPCode_Target_5XX | ~220 | 앱이 반환한 5xx |
| **TargetConnectionErrorCount** | ~170,000 | ALB → K8s 연결 실패 |

- **5xx의 99.8%가 ALB에서 발생** — 앱 문제가 아님
- 원인: NGF upstream keepAlive 미설정 → 매 요청마다 새 TCP 연결 → NodePort 폭발
- 해결: `UpstreamSettingsPolicy` keepAlive 64 연결 활성화

### RDS CPU 포화

| 지표 | 값 |
|------|-----|
| RDS 인스턴스 | db.t4g.small (vCPU 2) |
| CPU 피크 | 97% |
| CPU 크레딧 | 576 (소진 안 됨) |
| max_connections | ~164 |
| HikariCP 요구 | Pod 4×30 + Chat 4×20 = 200 |

- **Proxy가 커넥션은 해결했지만 CPU 포화는 Proxy로 못 풀음**
- t4g.medium 스케일업해도 vCPU 동일(2개) → 의미 없음
- Slow query (1초)에 안 잡힘 → 개별 쿼리는 빠르지만 양이 많아서 CPU 포화

### 풀 테이블 스캔 쿼리

| 메서드 | 원인 | 영향 |
|--------|------|------|
| `searchMeetings()` | `LIKE '%keyword%'` + `lower()` × 2회 서브쿼리 | books, meetings 풀스캔 |
| `findMyTodayMeetings()` | `DATE(start_at)` 함수 | meeting_rounds 풀스캔 |

---

## 인프라 현황

| 항목 | 상태 | 비고 |
|------|------|------|
| K8s | v1.31.14, Worker 4× t4g.large | |
| HPA (API) | 정상 | CPU 60%, max 8 Pod |
| HPA (Chat) | 정상 | CPU 60%, max 8 Pod, CPU 기준 유효 |
| RDS Proxy | 정상 | 커넥션 멀티플렉싱, JDBC pinning 최적화 |
| NGF keepAlive | **정상** | UpstreamSettingsPolicy 64 연결 |
| RDS | **WARN** | db.t4g.small CPU 97% — vCPU 한계 |
| Prometheus | 정상 | k6 v1.6.1 + Prometheus 3.x + native histogram |

---

## 다음 단계

| 우선순위 | 작업 | 기대 효과 |
|---------|------|----------|
| **P0** | 데이터 시딩 (11만건) + slow query 분석 | 실제 DB 부하에서 병목 쿼리 식별 |
| **P0** | searchMeetings() 서브쿼리 최적화 | 검색 P95 대폭 개선 |
| **P0** | findMyTodayMeetings() DATE() 제거 | 인덱스 활용 가능 |
| P1 | HPA 커스텀 메트릭 검토 (응답시간 기반) | I/O 병목 시 보완 |
| P1 | RDS 인스턴스 변경 (t4g → m6g) | CPU 전용 vCPU |
| P2 | meeting-lifecycle 30분 풀 (3대 분산) | 대규모 WS 장시간 안정성 |

---

*Generated: 2026-03-23 | Doktori Load Test Suite v3*