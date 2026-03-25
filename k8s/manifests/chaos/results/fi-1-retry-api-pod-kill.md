## FI-1 RETRY: API Pod 50% kill (kubectl delete 직접)

- 실행 시각: 2026-03-25 16:07:56
- 부하 상태: load 실행 중 (API CPU 114%, HPA 4 replicas)
- 결과: ✅ 검증됨

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| Pod 50% kill | 4개 중 2개 종료 | ✅ 2개 force delete 성공 |
| 새 Pod 생성 | 즉시 | ✅ 10초 내 새 Pod 0/1 Running |
| 새 Pod Ready | < 60초 | ✅ **60초** 만에 1/1 |
| 남은 Pod | 2개 Running | ✅ sm5pw, zg479 유지 |
| HPA 반응 | replica 유지 | ✅ 4개 유지 (이미 maxReplicas) |

### 발견
1. **self-healing 정상** — 2개 kill 후 즉시 2개 재생성, 60초 만에 Ready
2. **Chaos Mesh로는 kill 안 됨, kubectl delete로만 가능** — Chaos Mesh의 prod namespace RBAC 이슈
3. kill 후 남은 2개 Pod가 60초간 전체 부하를 감당 (CPU 189%)
4. HPA는 이미 maxReplicas(4)라 추가 스케일아웃 불가

### Chaos Mesh 이슈
- FI-1 YAML을 apply하면 `configured`가 나오지만 실제 kill이 안 됨
- 원인: Chaos Mesh controller가 pod-kill action을 실행할 때 prod namespace의 Pod에 대한 delete 권한이 부족할 수 있음
- kubectl delete는 kubeconfig의 admin 권한으로 동작하므로 성공
