## FI-16: metrics-server kill (HPA 판단 불가 검증)

- 실행 시각: 2026-03-25 15:56:02
- 부하 상태: load 실행 중 (API CPU 91%, HPA 4 replicas)
- 결과: ❌ kill 실패 — Chaos Mesh가 metrics-server Pod를 kill하지 못함

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| metrics-server kill | Pod 종료 후 재생성 | ❌ **Pod가 안 죽음** (Running 유지) |
| HPA TARGETS | `<unknown>` | CPU 76%→125% (정상 동작) |

### 원인 분석
- Chaos Mesh의 label selector `app.kubernetes.io/name: metrics-server`는 매칭됨 (이전에 확인)
- 하지만 Pod가 실제로 kill되지 않음
- 가능한 원인: Chaos Mesh RBAC가 kube-system namespace의 Pod를 삭제할 권한이 부족하거나, Helm 설치 Pod에 대한 추가 보호가 있을 수 있음

### 후속 조치
- `kubectl delete pod` 직접 실행으로 재검증 필요
- Chaos Mesh의 kube-system 접근 권한 확인 필요
