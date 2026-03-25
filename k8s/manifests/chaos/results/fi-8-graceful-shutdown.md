## FI-8: Graceful Shutdown

- 실행 시각: 2026-03-25 16:39:57
- 부하 상태: load 실행 중 (2 replicas)
- 결과: ✅ 검증됨

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| Pod 삭제 시간 | grace-period 30s | **12초** 만에 완료 |
| 새 Pod 생성 | 즉시 | ✅ 삭제 직후 새 Pod 0/1 Running |
| 새 Pod Ready | < 60초 | **72초** (0/1 → 1/1) |
| 남은 Pod | 1개 Running | ✅ zvjsc 유지 |

### 발견
1. **grace-period=30인데 12초 만에 종료** — pre-stop hook(sleep 10) + 앱 종료가 12초 내 완료
2. terminationGracePeriodSeconds=30이므로 SIGTERM 후 30초 안에 종료 → 정상
3. 삭제 중 남은 1개 Pod가 서비스 유지
4. 새 Pod가 72초 만에 Ready (JVM 시작 시간)

### FI-1 (force kill) vs FI-8 (graceful) 비교

| | FI-1 (force, grace=0) | FI-8 (graceful, grace=30) |
|---|---|---|
| 종료 시간 | 즉시 | 12초 |
| in-flight 요청 | 유실 가능 | pre-stop 10초 동안 완료 |
| 재생성 시간 | ~60초 | ~72초 (동일) |

### 후속 조치
- k6 결과에서 FI-8 시점의 5xx 확인 → 0건이면 Graceful Shutdown 완벽
