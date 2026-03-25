## FI-3: API→DB 200ms 지연

- 실행 시각: 2026-03-25 16:15:00
- 부하 상태: load 실행 중 (API CPU 86%, HPA 4 replicas)
- 결과: ✅ 검증됨 — 흥미로운 발견

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| NetworkChaos 적용 | 200ms 지연 주입 | ✅ 정상 적용 |
| API CPU 변화 | 증가 예상 | ❌ **86% → 51% → 44%로 감소!** |
| HPA 반응 | 유지 | 4→2로 **스케일다운** (CPU 60% 미만) |
| 서비스 영향 | latency 증가 | Grafana에서 P95 확인 필요 |

### 타임라인

| 시간 | CPU | Replicas |
|------|-----|----------|
| BEFORE | 86% | 4 |
| +30s | 51% | 4 |
| +60s | 44% | 4 |
| +120s | 58% | **2** (스케일다운!) |

### 발견
1. **DB 지연 주입 시 CPU가 오히려 감소** — DB 응답을 기다리는 동안 스레드가 idle 상태가 되어 CPU utilization이 떨어짐
2. CPU가 60% 미만으로 떨어지면서 **HPA가 스케일다운** (4→2). 이건 의도치 않은 부작용
3. 실제로는 응답 latency가 200ms+ 증가했을 것이므로, **CPU 기반 HPA는 DB 지연 장애를 감지 못 하는 맹점**
4. HikariCP pending 상태는 Grafana에서 확인 필요

### 시사점
- CPU HPA만으로는 DB 지연 장애 시 오히려 Pod를 줄여버리는 역효과 발생
- latency 기반 HPA 또는 HikariCP pending 기반 스케일링이 더 적절할 수 있음
- 이건 "FI에서 발견한 설계 결함"으로 포트폴리오에 가치 있는 발견

### 후속 조치
- Grafana에서 이 시점 P95 latency, HikariCP pending 확인
- latency 기반 HPA 또는 Circuit Breaker 도입 검토
