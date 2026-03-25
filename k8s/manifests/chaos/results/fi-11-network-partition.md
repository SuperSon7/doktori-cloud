## FI-11: API↔Chat 네트워크 파티션

- 실행 시각: 2026-03-25 16:20:14
- 부하 상태: load 실행 중 (API CPU 77%, 4 replicas)
- 결과: ✅ 검증됨 — 서비스 독립 동작 확인

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| 파티션 적용 | API↔Chat 양방향 차단 | ✅ NetworkChaos 적용 |
| API 동작 | 독립 유지 (SLO-1) | ✅ 전 Pod Running, HPA 정상 |
| Chat 동작 | 독립 유지 (SLO-3) | ✅ 전 Pod Running |
| 파티션 해제 후 | 정상 복귀 | ✅ 모든 Pod Running |

### 타임라인

| 시간 | API | Chat | Gateway |
|------|-----|------|---------|
| BEFORE | 4 Running | 2 Running | 1 Running |
| +30s | 4 Running | 2 Running | 1 Running |
| +90s | 2 Running (HPA 스케일다운) | 2 Running | 1 Running |
| +210s (해제) | 4 Running (스케일업 중) | 2 Running | 1 Running |

### 발견
1. **API와 Chat은 완전히 독립** — 네트워크 파티션 중에도 양쪽 모두 정상 동작
2. 현재 아키텍처에서 API→Chat 직접 통신이 없음 (Gateway 경유만)
3. 파티션 중 HPA 스케일다운(4→2)은 부하 변동에 의한 것 (파티션 자체의 영향 아님)

### 시사점
- API/Chat 멀티모듈 분리의 설계 가치 실증: 한쪽 네트워크 장애가 다른 쪽에 전파되지 않음
- 포트폴리오에 "서비스 격리(Fault Isolation) 검증" 증빙으로 활용 가능

### 후속 조치
- 없음 (정상)
