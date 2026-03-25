## FI-12: AZ 장애 (노드 drain)

- 실행 시각: 2026-03-25 16:43:18 ~ 16:43:52
- 대상: ip-10-1-24-206 (api 1개 + gateway 1개 + coredns 1개 + argocd 등)
- 부하 상태: load 실행 중
- 결과: ✅ 검증됨

### 관측값

| 지표 | 기대 | 실측 |
|------|------|------|
| drain 소요 | < 2분 | ✅ **34초** (16:43:18 → 16:43:52) |
| evict된 Pod | 해당 노드 전체 | 7개 evict (api, gateway, coredns, argocd, external-secrets, chaos-controller) |
| Pod 재스케줄링 | 다른 노드 | ✅ **10초 내** 전부 다른 노드에서 Running |
| Gateway 재생성 | 다른 노드 | ✅ ip-10-1-28-254에서 Running (42초) |
| 서비스 중단 | 최소화 | ✅ drain 중 남은 노드의 Pod가 서비스 유지 |

### 타임라인

| 시간 | 이벤트 |
|------|--------|
| 16:43:18 | drain 시작 (cordon + evict) |
| 16:43:52 | drain 완료 (34초) |
| +10초 | 전체 Pod 다른 노드에서 Running |
| +60초 | HPA가 추가 Pod 생성 (부하 대응) |
| | uncordon으로 복구 |

### 발견
1. **PDB 정상 동작** — drain 시 maxUnavailable=1 준수하며 순서대로 evict
2. **topology spread 발견**: AZ label이 비어있음 (`AZ=`). topology.kubernetes.io/zone label이 안 붙어있어서 topology spread가 AZ 기준으로 분산하지 못하고 있음
3. **CoreDNS도 함께 evict** — 하지만 다른 노드에서 즉시 재생성 (FI-15에서 확인한 대로)
4. Gateway evict 후 다른 노드에서 42초 만에 Running — SPOF가 아닌 상태(replica 2)에서는 안전

### 중요 발견: AZ label 누락
```
ip-10-1-24-206  AZ=  (빈 값)
ip-10-1-28-254  AZ=  (빈 값)
```
topology.kubernetes.io/zone label이 없으므로:
- topologySpreadConstraints의 zone 기반 분산이 **동작하지 않음**
- 모든 Pod가 같은 AZ에 몰릴 수 있음
- kubeadm 클러스터에서는 자동으로 안 붙으므로 수동 추가 필요

### 후속 조치 (필수)
- 워커 노드에 `topology.kubernetes.io/zone` label 수동 추가
- label 추가 후 Pod가 AZ별로 분산되는지 확인
