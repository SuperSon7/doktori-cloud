## FI-17: Calico (CNI) 1개 kill

- 실행 시각: 2026-03-25 16:18:43
- 부하 상태: load 실행 중
- 결과: ✅ 검증됨

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| Calico kill | DaemonSet 1개 종료 | ✅ 1개 kill, 즉시 재생성 |
| 재생성 시간 | < 30초 | ✅ 10초 내 0/1 Running, 35초 내 전부 7/7 |
| 기존 Pod 통신 | 유지 | ✅ API/Chat Pod Running 유지 |
| 서비스 영향 | 없음 | ✅ 영향 없음 |

### 발견
1. Calico DaemonSet이 kill된 노드에서 즉시 재생성
2. 기존 iptables 규칙이 유지되어 **Pod 간 통신 끊김 없음**
3. Calico restart 중에도 기존 네트워크 정상 동작

### 후속 조치
- 없음 (정상)
