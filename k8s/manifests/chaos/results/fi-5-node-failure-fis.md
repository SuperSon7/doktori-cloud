## FI-5: 워커 노드 장애 (AWS FIS)

- 실행 시각: 2026-03-25 16:31 ~ 16:36
- FIS Experiment: EXPkVPXxZK7rmCWbdU (Template: EXT3MWrt9gFfrroi)
- 대상: i-002e5b39733795846 (ip-10-1-61-29)
- 부하 상태: load 실행 중
- 결과: ✅ 검증됨

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| 노드 stop | NotReady | ✅ 16:32:57 NotReady 확인 (~30초 만에) |
| Pod 재스케줄링 | 다른 노드로 이동 | ✅ 해당 노드의 api Pod가 이미 HPA 스케일다운으로 제거됨 |
| 서비스 영향 | SLO 유지 | ✅ **4분간 전체 Pod Running, 서비스 중단 없음** |
| 노드 복구 | 5분 후 자동 start | ✅ FIS 완료, 인스턴스 running |
| 남은 워커 | 3/4 | ✅ 3개 노드로 서비스 지속 |

### 타임라인

| 시각 | 노드 상태 | prod Pod |
|------|----------|---------|
| 16:32:26 | 7 Ready | api 2, chat 2, gateway 1 |
| 16:32:57 | **6 Ready, 1 NotReady** | api 2, chat 2, gateway 1 (영향 없음) |
| 16:33:27~16:35:58 | 6 Ready, 1 NotReady | 동일 — **서비스 안정** |

### 발견
1. **멀티 노드 HA 정상 동작** — 워커 1대 죽어도 나머지 3대로 서비스 지속
2. target 노드(ip-10-1-61-29)에 api Pod 1개가 있었지만, HPA 스케일다운으로 이미 제거된 상태에서 FIS 실행됨 → 직접적인 Pod 재스케줄링은 관찰 못 함
3. topology spread가 Pod를 여러 노드에 분산시켜놓은 덕분에 한 노드 장애에도 서비스 영향 없음
4. FIS `startInstancesAfterDuration: PT5M`으로 5분 후 자동 복구

### 후속 조치
- Pod가 target 노드에 확실히 있는 상태에서 재검증하면 Pod 재스케줄링 과정도 관찰 가능
- FI-12 (AZ 장애)에서 더 큰 규모의 노드 장애 검증 예정
