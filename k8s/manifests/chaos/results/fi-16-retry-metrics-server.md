## FI-16 RETRY: metrics-server kill (kubectl delete 직접)

- 실행 시각: 2026-03-25 16:00:06
- 부하 상태: load 실행 중 (API CPU 105%, HPA 4 replicas)
- 결과: ✅ 검증됨

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| metrics-server kill | Pod 종료 후 재생성 | ✅ force delete 성공 |
| HPA TARGETS | `<unknown>` | ✅ **cpu: `<unknown>`**, memory: `<unknown>` |
| kubectl top | 에러 | ✅ `Metrics API not available` |
| metrics-server 복구 | < 2분 | ✅ **71초** 만에 Running 1/1 |
| HPA 복구 | TARGETS 정상 | ✅ 복구 후 cpu: 76% 표시 |
| 서비스 영향 | 없음 | ✅ API/Chat Pod Running 유지 |

### 발견
1. **Chaos Mesh로는 metrics-server kill 불가** — kubectl delete로만 가능. Chaos Mesh RBAC 이슈
2. **HPA가 `<unknown>` 상태에서 기존 replica 수 유지** — 스케일 판단 안 하지만 기존 4개는 그대로
3. **복구 71초** — metrics-server 재시작 후 HPA 정상 동작

### 후속 조치
- Chaos Mesh fi-16 YAML 대신 kubectl 직접 실행 방식으로 변경 권장
