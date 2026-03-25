## FI-14: Alloy (모니터링 파이프라인) kill

- 실행 시각: 2026-03-25 16:01:17
- 부하 상태: load 실행 중
- 결과: ✅ 검증됨

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| Alloy Pod kill | 전체 DaemonSet 재생성 | ✅ 7개 전부 kill → 10초 내 재생성 |
| Alloy 복구 | < 1분 | ✅ **35초** 만에 전부 Running 1/1 |
| 서비스 영향 | 없음 | ✅ API/Chat Pod Running 유지 (일부 Terminating은 HPA 스케일다운) |
| Grafana 메트릭 갭 | 최소화 | Grafana에서 확인 필요 (WAL replay 여부) |

### 발견
1. **모니터링 장애가 서비스에 영향 없음 확인** — Alloy 7개 전부 죽어도 API/Chat은 정상
2. DaemonSet이므로 Pod kill 후 **자동 재생성** → 35초 만에 전체 복구
3. prod Pod 중 일부 Terminating은 **FI가 아닌 HPA 스케일다운** (부하 변동)

### 후속 조치
- Grafana에서 이 시점의 메트릭 갭 확인 필요 (Alloy WAL이 갭을 메꾸는지)
