# FI 실험 종합 결과

실행일: 2026-03-25 | 부하: 분산 러너 6시간 load

## 결과 매트릭스

### 컴포넌트 단위

| ID | 시나리오 | 결과 | 핵심 발견 |
|----|---------|------|----------|
| FI-15A | CoreDNS 1개 kill | ✅ 통과 | HA 정상, 10초 내 재생성, DNS 서비스 지속 |
| FI-15B | CoreDNS 전체 kill | ✅ 통과 | 5초 내 재생성, DNS 캐시로 즉시 복구 |
| FI-16 | metrics-server kill | ✅ 통과 (kubectl) | HPA `<unknown>` → 71초 복구. Chaos Mesh는 kill 불가 |
| FI-14 | Alloy kill | ✅ 통과 | 35초 전체 복구, 서비스 영향 없음 |
| FI-1 | API Pod 50% kill | ✅ 통과 (kubectl) | 60초 Ready, self-healing 정상. Chaos Mesh kill 불가 |
| FI-2 | Chat Pod kill | ✅ 통과 | 65초 Ready, 남은 Pod가 서비스 유지 |
| FI-4 | CPU Stress | ⚠️ 부분 | CPU 500%+ 주입 성공, HPA 이미 maxReplicas라 스케일아웃 관찰 불가 |
| FI-3 | DB 200ms 지연 | ⚠️ 발견 | **CPU 감소 → HPA 스케일다운 역반응** |
| FI-9 | Gateway kill | ⚠️→✅ | **SPOF 발견** → replica 2로 증설 → 재검증 통과 |
| FI-17 | Calico kill | ✅ 통과 | 10초 재생성, 기존 iptables 유지 |
| FI-11 | API↔Chat 파티션 | ✅ 통과 | 양쪽 독립 동작 확인, Fault Isolation 실증 |
| FI-7 | Rolling Update | ✅ 통과 | 81초 완료, maxUnavailable=0 준수, 항상 2+ Running |
| FI-8 | Graceful Shutdown | ✅ 통과 | 12초 종료, pre-stop hook 정상 |

### 인프라 레벨

| ID | 시나리오 | 결과 | 핵심 발견 |
|----|---------|------|----------|
| FI-5 | 워커 노드 장애 (FIS) | ✅ 통과 | 30초 NotReady, 나머지 노드로 서비스 지속 |
| FI-12 | AZ 장애 (drain) | ✅ 통과 + 발견 | 34초 drain 완료, **AZ label 누락 발견** → 수동 추가 |
| FI-10 | 연쇄 장애 | ⚠️ 발견 | DB 지연 시 CPU 급감 → HPA 스케일다운 역반응 (FI-3과 동일 패턴) |
| FI-13 | Game Day (21분) | ✅ 통과 | 5개 연속 장애 후 전체 복구, k8s 복원력 실증 |

### 스킵

| ID | 사유 |
|----|------|
| FI-6 | RabbitMQ가 k8s 외부 운영 |

## 주요 발견 및 개선 사항

### 발견 1: Gateway SPOF → 해결
- **발견**: FI-9에서 Gateway replica=1, kill 시 ~30초 서비스 다운
- **조치**: replica 1→2 증설
- **재검증**: ✅ 1개 kill해도 서비스 지속

### 발견 2: CPU HPA가 DB 지연을 감지 못 함
- **발견**: FI-3, FI-10에서 DB 지연 주입 시 CPU가 오히려 감소 → HPA 스케일다운
- **원인**: DB 응답 대기 중 스레드 idle → CPU utilization 감소
- **영향**: 실제 응답 latency 500ms+ 증가인데 HPA는 "부하 줄었다"고 판단
- **대안**: latency 기반 HPA 또는 HikariCP pending alert

### 발견 3: AZ label 누락
- **발견**: FI-12에서 `topology.kubernetes.io/zone` label이 비어있음
- **영향**: topologySpreadConstraints zone 분산이 동작하지 않음
- **조치**: 7개 노드에 AZ label 수동 추가 완료

### 발견 4: Chaos Mesh가 일부 Pod kill 불가
- **발견**: FI-1(prod API), FI-16(kube-system metrics-server)에서 PodChaos 적용해도 kill 안 됨
- **우회**: kubectl delete로 직접 kill하여 검증 완료
- **원인**: RBAC 또는 Chaos Mesh CRD 호환성 이슈 (미해결)

### 발견 5: HPA thrashing
- **발견**: 부하 테스트 중 HPA가 2→6→4→6→2 반복
- **원인**: scaleUp stabilizationWindowSeconds=0 (즉시 반응)
- **조치**: 0→30초로 변경 (Git 반영 완료)

## 설정 변경 이력

| 항목 | 변경 전 | 변경 후 | 근거 |
|------|--------|--------|------|
| API HPA maxReplicas | 8 | 4 | 워커 4대 대비 적정 |
| API HPA scaleUp stabilization | 0s | 30s | thrashing 방지 |
| Chat HPA 메트릭 | CPU 60% | 세션수 50 + Memory 85% | WebSocket은 CPU 무반응 |
| Gateway replicas | 1 | 2 | FI-9 SPOF 발견 |
| API/Chat readinessProbe | successThreshold 없음 | 2 | JVM 워밍업 시간 확보 |
| 노드 AZ label | 누락 | 수동 추가 | FI-12에서 발견 |

## FIS 실험

| ID | Template | Instance | 결과 |
|----|----------|----------|------|
| FI-5 | EXT3MWrt9gFfrroi | i-002e5b39733795846 | ✅ 완료 (EXPkVPXxZK7rmCWbdU) |
| FIS IAM Role | doktori-fis-role | — | 생성 완료 |
