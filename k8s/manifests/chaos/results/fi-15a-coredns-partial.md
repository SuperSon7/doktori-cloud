## FI-15A: CoreDNS 1개 kill (HA 검증)

- 실행 시각: 2026-03-25 15:49:48
- 부하 상태: load 실행 중 (API CPU 40%)
- 결과: ✅ 검증됨

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| CoreDNS 재생성 시간 | < 30초 | **10초 이내** Running |
| DNS FQDN 해석 | 정상 | ✅ `kubernetes.default.svc.cluster.local` 정상 |
| 서비스 영향 | 없음 | ✅ API/Chat Pod Running 유지 |
| 남은 CoreDNS | 1개 이상 | ✅ 1개 유지 + 1개 재생성 (다른 노드) |

### 발견
- CoreDNS 2개가 다른 노드(ip-10-1-24-206, ip-10-1-69-143)에 분산되어 있어 1개 kill해도 나머지가 DNS 서비스 유지
- 새 Pod도 10초 내에 Running → CoreDNS는 경량이라 시작이 빠름

### 후속 조치
- 없음 (정상)