# Chaos Mesh — 장애 주입 실험

## 개요

독토리 k8s 인프라의 복원력을 검증하기 위한 Fault Injection 실험 매니페스트.
Chaos Mesh CRD 기반으로 선언형 YAML로 실험을 정의하고, kubectl로 적용/중단한다.

## 사전 요구사항

- k8s 클러스터 정상 동작 (API/Chat Pod Running)
- Helm 3 설치됨
- HPA, PDB 적용 완료 (`install-observability.sh` 실행 후)
- Grafana 모니터링 정상 (SLO 대시보드 확인 가능)

## 설치

```bash
# master 노드에서 실행
cd /path/to/k8s
chmod +x install-chaos-mesh.sh
./install-chaos-mesh.sh
```

설치 후 확인:
```bash
kubectl get pods -n chaos-testing        # 전부 Running 확인
kubectl get crd | grep chaos-mesh        # CRD 등록 확인
```

Dashboard 접속:
```bash
kubectl port-forward -n chaos-testing svc/chaos-dashboard 2333:2333
# http://localhost:2333
```

## 실험 목록

| ID | 파일 | 대상 | 내용 | SLO |
|----|------|------|------|-----|
| FI-1 | `fi-1-api-pod-kill.yaml` | API Pod | 50% Pod 강제 종료 | SLO-1 |
| FI-2 | `fi-2-chat-pod-kill.yaml` | Chat Pod | 1개 Pod 강제 종료 | SLO-3 |
| FI-3 | `fi-3-db-latency.yaml` | API→DB | 200ms 네트워크 지연 | SLO-2 |
| FI-4 | `fi-4-cpu-stress.yaml` | API Pod | CPU 80% stress | SLO-1,2 |
| FI-5 | `fi-5-node-failure.yaml` | 워커 노드 | 노드 종료 (AWS FIS/drain) | SLO-1,3 |
| FI-6 | `fi-6-rabbitmq-kill.yaml` | RabbitMQ | Pod 강제 종료 | 보조 지표 |
| FI-7 | `fi-7-rolling-update.sh` | Deployment | 부하 중 Rolling Update → 5xx 0건 확인 | SLO-1 |
| FI-8 | `fi-8-graceful-shutdown.sh` | API Pod | 부하 중 Pod graceful delete → 요청 유실 확인 | SLO-1 |
| FI-9 | `fi-9-gateway-kill.yaml` | Gateway Pod | Nginx Gateway Pod kill → SPOF 여부 확인 | SLO-1,3 |

**시스템/클라우드 레벨**

| ID | 파일 | 대상 | 내용 | SLO |
|----|------|------|------|-----|
| FI-10 | `fi-10-cascading-failure.sh` | DB→API→전체 | k6 stress + DB 500ms → 연쇄 장애 관찰 | SLO-1,2 |
| FI-11 | `fi-11-network-partition.yaml` | API↔Chat | 서비스 간 네트워크 파티션 → 격리 검증 | SLO-1,3 |
| FI-12 | `fi-12-az-failure.sh` | 워커 노드 (AZ) | AZ 전체 drain → 멀티 AZ HA 검증 | SLO-1,3 |
| FI-13 | `fi-13-gameday.sh` | 전 시스템 | 30분간 5분 간격 랜덤 FI 연쇄 (Game Day) | SLO-1~4 |
| FI-14 | `fi-14-monitoring-kill.yaml` | Alloy | 모니터링 장애 → 서비스 영향 없음 확인 | 관측성 |

## 실행 방법

```bash
cd manifests/chaos

# 실험 시작
./run-experiment.sh apply fi-1

# 상태 확인
./run-experiment.sh status

# 실험 중단
./run-experiment.sh delete fi-1

# 전체 비상 중단
./run-experiment.sh stop-all
```

### FI-7, FI-8 (k6 + kubectl 조합)

FI-7, FI-8은 Chaos Mesh가 아닌 쉘 스크립트로 실행한다. **반드시 k6 부하를 먼저 실행한 상태에서 실행**:

```bash
# 터미널 1: k6 부하 실행
k6 run --env BASE_URL=http://<endpoint>/api load-tests/k6/scenarios/load.js

# 터미널 2: FI-7 (Rolling Update)
./fi-7-rolling-update.sh <new-image-tag>

# 또는 FI-8 (Graceful Shutdown)
./fi-8-graceful-shutdown.sh
```

## ⚠️ 주의사항

### 반드시 지키기

1. **한 번에 하나의 실험만 실행** — 복합 장애는 개별 검증 완료 후 마지막에
2. **Grafana 모니터링 화면을 열어둔 상태에서 실행** — 실험 시작 전 대시보드 준비
3. **실험 전후 스크린샷 저장** — 포트폴리오 증빙용

### 실행 전 확인

- `kubectl get pods -n prod` → 모든 Pod Running 상태인지
- `kubectl get hpa -n prod` → HPA TARGETS에 CPU % 표시되는지
- Grafana에서 SLO-1~4 패널이 정상 표시되는지

### 수정 필요 사항

- **`fi-3-db-latency.yaml`**: DB 엔드포인트가 k8s 내부가 아닌 외부(RDS 등)인 경우 `externalTargets`에 IP/CIDR 지정 필요. 현재는 Pod 간 NetworkChaos로 설정됨
- **`fi-6-rabbitmq-kill.yaml`**: `labelSelectors.app: rabbitmq` → 실제 RabbitMQ 배포의 label에 맞게 수정
- **`fi-5-node-failure.yaml`**: YAML이 아닌 참조 문서. AWS FIS 또는 `kubectl drain`으로 실행

### 비상 중단

실험이 예상대로 동작하지 않을 때:

```bash
# 방법 1: 헬퍼 스크립트
./run-experiment.sh stop-all

# 방법 2: kubectl 직접
kubectl delete podchaos,networkchaos,stresschaos --all -n chaos-testing

# 방법 3: Chaos Mesh Dashboard에서 Pause/Archive
```

### 비용

- Chaos Mesh 자체는 무료 (k8s CRD)
- AWS FIS (FI-5): 실험당 $0.10/분
- 실험 중 HPA 스케일아웃으로 추가 Pod 생성 → 노드 리소스 소모 주의

## 관련 문서

- [ADR-007: Fault Injection Strategy](https://github.com/100-hours-a-week/5-team-service-wiki/wiki/Cloud/ADRs/ADR-007-Fault-Injection-Strategy)
- [SLI/SLO 정의서 v2](https://github.com/100-hours-a-week/5-team-service-wiki/wiki/Cloud/SLI-SLO-정의서-v2)