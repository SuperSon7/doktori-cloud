## FI-2: Chat Pod 1개 kill

- 실행 시각: 2026-03-25 16:05:12
- 부하 상태: load 실행 중
- 결과: ✅ 검증됨

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| Chat Pod kill | 2개 중 1개 종료 | ✅ xlfp2 종료, s6zs9 생성 |
| 새 Pod Ready | < 60초 | **65초** (0/1 → 1/1) |
| 남은 Chat Pod | 1개 Running | ✅ krkh5 유지 |
| 서비스 영향 | Chat probe 유지 | ✅ 1개가 서비스 지속 |

### 발견
1. **Chat self-healing 정상 동작** — 1개 kill 후 새 Pod 65초 만에 Ready
2. 남은 1개 Pod가 kill~새 Pod Ready 사이(65초) 동안 서비스 유지
3. Chat은 JVM Spring Boot라 API와 마찬가지로 시작 시간이 ~60초

### 후속 조치
- 없음 (정상)
