## FI-1: API Pod 50% kill

- 실행 시각: 2026-03-25 16:03:06
- 부하 상태: load 실행 중 (API CPU 159%, HPA 4 replicas)
- 결과: ⚠️ Chaos Mesh가 kill하지 못함 — 이전 실험 리소스 잔존 가능

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| Pod 50% kill | 4개 중 2개 종료 | ❌ **0개 종료** — 4개 전부 Running 유지 |
| 재생성 | kill 후 자동 재생성 | 해당 없음 |

### 원인 분석
- `kubectl apply` 결과가 `configured` (created가 아님) → 이전 FI-1 실험이 남아있었을 가능성
- Chaos Mesh PodChaos의 duration이 30초이므로 이미 만료된 상태에서 재적용 시 kill이 안 될 수 있음
- FI-16에서도 동일하게 Chaos Mesh가 kube-system Pod를 kill 못 함 → RBAC 이슈 가능

### 후속 조치
- kubectl delete로 직접 재검증 필요
- Chaos Mesh가 prod namespace Pod를 kill할 수 있는지 별도 확인
