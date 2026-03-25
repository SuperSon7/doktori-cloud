## FI-7: Rolling Update 무중단 배포

- 실행 시각: 2026-03-25 16:38:06 ~ 16:39:27
- 부하 상태: load 실행 중
- 결과: ✅ 검증됨 — 무중단 배포 확인

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| 배포 중 Running Pod | 항상 1개 이상 | ✅ 최소 2개 Running 유지 |
| 새 Pod Ready 시간 | < 60초 | ~50초 (0/1 → 1/1) |
| 전체 Rollout 시간 | < 3분 | **81초** (16:38:06 → 16:39:27) |
| maxUnavailable=0 준수 | 기존 Pod 먼저 죽지 않음 | ✅ 새 Pod Ready 후에 기존 Pod Terminating |

### 타임라인

| 시간 | 기존 Pod | 새 Pod | 상태 |
|------|---------|--------|------|
| +10s | 2 Running | 1 (0/1) | 새 Pod 시작 중 |
| +20~40s | 2 Running | 1 (0/1) | JVM 워밍업 |
| +50s | 1 Running + **1 Terminating** | 1 Running + 1 (0/1) | 첫 새 Pod Ready → 기존 1개 종료 시작 |
| +60~80s | 1 Running | 1 Running + 1 (0/1) | 두 번째 교체 진행 |
| +81s | 0 | 2 Running | **완료** |

### 발견
1. **maxUnavailable=0 정상 동작** — 새 Pod가 Ready(1/1)된 후에야 기존 Pod Terminating
2. **항상 최소 2개 Running** — 배포 중 서비스 중단 없음
3. **maxSurge=1** — 한 번에 1개씩만 추가하여 리소스 급증 방지
4. 전체 81초 소요 (2개 Pod 교체)

### 후속 조치
- k6 부하 테스트 결과에서 이 시점 5xx, latency 스파이크 확인 필요
- 현재 로그로는 "서버 side에서 중단 없음"만 확인, 클라이언트 side는 Grafana로 확인
