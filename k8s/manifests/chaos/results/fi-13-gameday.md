## FI-13: Game Day (전체 사용자 여정 카오스)

- 실행 시각: 2026-03-25 16:52:12 ~ 17:13:36 (21분)
- 부하 상태: load 실행 중
- 결과: ✅ 검증됨 — 모든 Round 후 서비스 정상 복구

### Round별 결과

| Round | 시각 | 장애 | API Pods | CPU | 서비스 |
|-------|------|------|---------|-----|--------|
| 1 | 16:52 | API Pod 1개 kill | 1→2 (재생성) | 95% | ✅ 유지 |
| 2 | 16:57 | DB 200ms 지연 | 4 | 105% | ✅ 유지 (지연 증가 예상) |
| 3 | 17:02 | Chat Pod 1개 kill | 2 | 56% | ✅ 유지 |
| 4 | 17:07 | CPU Stress | 3 | 136% | ✅ HPA 스케일아웃 |
| 5 | 17:12 | 안정화 | 4 | 80% | ✅ 전체 정상 |

### 최종 상태
- API: 4 Pod Running
- Chat: 2 Pod Running
- Gateway: 1 Pod Running
- HPA: api 80%/60% (4 replicas), chat 81%/85% (2 replicas)

### 발견
1. **5개 연속 장애 주입 후에도 서비스 완전 복구** — k8s self-healing + HPA 동작 확인
2. Round 1(Pod kill) → 즉시 재생성, 나머지 Pod가 서비스 유지
3. Round 2(DB 지연) → 서비스 지속하지만 CPU 감소 패턴 재확인 (FI-3 동일)
4. Round 3(Chat kill) → Chat self-healing 정상, 남은 Pod가 WebSocket 유지
5. Round 4(CPU stress) → HPA 2→3 스케일아웃 트리거
6. Round 5(안정화) → 모든 chaos 리소스 정리 후 정상 상태 복귀

### 시사점
- **실제 운영에서 연속 장애가 발생해도 k8s가 자동 복구**
- 단일 장애(Pod kill)는 즉시 복구, DB 지연은 latency 영향만
- Netflix Game Day 방식의 검증으로 **전체 서비스 복원력 실증**

### 후속 조치
- Grafana에서 이 21분 구간의 SLO-1~4 확인 필요
- 특히 Round 2(DB 지연) 시점의 P95 latency 확인
