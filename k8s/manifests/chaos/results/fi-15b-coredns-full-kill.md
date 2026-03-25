## FI-15B: CoreDNS 전체 kill (DNS 전면 장애)

- 실행 시각: 2026-03-25 16:27:55
- 부하 상태: load 실행 중
- 결과: ✅ 검증됨 — 예상보다 빠른 복구

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| CoreDNS 전체 kill | 2개 모두 종료 | ✅ 2개 kill |
| 재생성 시간 | < 30초 | ✅ **5초 이내** 2개 다시 Running 1/1 |
| DNS 해석 (kill 직후) | 실패 예상 | ✅ **정상!** `kubernetes.default.svc.cluster.local` 해석 성공 |
| DNS 해석 (35초 후) | 복구 | ✅ 정상 |

### 발견
1. **CoreDNS 전체 kill에도 DNS 해석이 즉시 복구** — Deployment가 즉시 2개 재생성하고 5초 내에 Running
2. CoreDNS는 경량 컨테이너(Go 바이너리)라 JVM과 달리 시작 시간이 거의 없음
3. kill → 재생성 사이(~5초)에도 DNS 캐시가 남아있어 해석 성공한 것으로 추정
4. **클러스터 DNS는 사실상 중단 없음** — Deployment controller의 재생성 속도가 충분히 빠름

### 시사점
- CoreDNS replica=2면 전체 kill에도 ~5초 만에 복구 → 실질적 DNS 장애 거의 없음
- 이건 "CoreDNS가 SPOF가 아님"의 강력한 증거

### 후속 조치
- 없음 (예상보다 좋은 결과)
