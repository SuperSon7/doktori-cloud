## FI-9: Gateway (Nginx) Pod kill — SPOF 확인

- 실행 시각: 2026-03-25 16:17:35
- 부하 상태: load 실행 중
- 결과: ⚠️ **SPOF 확인** — Gateway replica 1개라 kill 시 전체 트래픽 중단

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| Gateway kill | Pod 종료 | ✅ Chaos Mesh로 kill 성공 |
| 서비스 중단 | SPOF면 중단 | ⚠️ **5초 시점 ContainerCreating** — 이 구간 트래픽 중단 |
| 복구 | 재생성 | ✅ **35초** 만에 Running 1/1 |
| replica 수 | 1개 | ✅ 확인 — **SPOF** |

### 발견
1. **Gateway가 SPOF** — replica 1개. kill 시 전체 서비스 약 30초 다운
2. Chaos Mesh가 nginx-gateway namespace의 Pod도 정상 kill (prod와 달리)
3. 재생성은 빠름(35초)이지만 30초 다운타임은 SLO 위반

### 후속 조치 (필수)
- **Gateway replica 2개로 증설** — `nginx-gw` Deployment replicas: 1 → 2
- PDB 추가 (maxUnavailable: 1)
- 증설 후 FI-9 재검증
