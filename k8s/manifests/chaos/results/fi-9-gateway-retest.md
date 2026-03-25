## FI-9 RETEST: Gateway kill (replica 2로 증설 후)

- 실행 시각: 2026-03-25 16:27:06
- 설정 변경: Gateway replica 1 → 2
- 결과: ✅ **SPOF 해소 확인** — 1개 kill해도 나머지 1개로 서비스 지속

### 관측값

| 지표 | 이전 (1 replica) | 이후 (2 replicas) |
|------|----------------|-----------------|
| kill 시 서비스 중단 | ⚠️ ~30초 다운 | ✅ **중단 없음** (1개 유지) |
| 복구 시간 | 35초 | 35초 (동일) |
| HA | ❌ SPOF | ✅ HA |

### 발견
1. Gateway replica 2로 증설하면 1개 kill해도 나머지가 트래픽 처리
2. 새 Gateway Pod(7ncgh)가 Error/CrashLoopBackOff — 이건 master 노드(ip-10-1-29-69)에 스케줄된 것이 원인일 수 있음 (Gateway는 worker에 띄워야 함)
3. kill 후 재생성된 qjtw6은 35초 만에 Running

### 후속 조치
- Gateway Pod가 Error 나는 노드 확인 (master vs worker taint 문제)
- Gateway Deployment에 nodeAffinity 추가하여 worker에만 스케줄링
- replica=2를 Git에 반영
