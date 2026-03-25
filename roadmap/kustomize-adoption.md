# Kustomize 도입 Roadmap

> plain YAML manifest → Kustomize 전환으로 manifest 관리 체계화
>
> 트래킹 시작: 2026-03-20

---

## 진행 현황

| Phase | 제목 | 상태 | 완료일 | 비고 |
|:-----:|------|:----:|:-----:|------|
| 0 | [monitoring 디렉토리 전환](#phase-0-monitoring-디렉토리-전환) | 🔲 Todo | - | configMapGenerator로 Alloy 자동 reload 해결 |
| 1 | [workloads/hpa/security 전환](#phase-1-나머지-디렉토리-전환) | 🔲 Todo | - | 기본 resources 리스트 |
| 2 | [Argo CD Application 검증](#phase-2-argo-cd-application-검증) | 🔲 Todo | - | Kustomize 자동 감지 확인 |

---

## Phase 0: monitoring 디렉토리 전환

**목표:** configMapGenerator로 Alloy ConfigMap 해시 자동화 → config 변경 시 pod 자동 재시작

### Checklist
- [ ] `config.alloy` 파일을 alloy-configmap.yaml에서 분리
- [ ] `kustomization.yaml` 생성 (configMapGenerator + resources)
- [ ] `alloy-configmap.yaml` 삭제 (configMapGenerator가 대체)
- [ ] alloy-daemonset.yaml의 configMap 참조가 Kustomize에 의해 자동 업데이트되는지 확인
- [ ] Argo CD sync 후 Alloy pod가 해시 suffix 포함된 ConfigMap 마운트하는지 확인

### 산출물 (예상)
- `k8s/manifests/monitoring/kustomization.yaml`
- `k8s/manifests/monitoring/config.alloy` (분리된 설정 파일)

### 참고
- Argo CD는 이미 `--load-restrictor LoadRestrictionsNone` 설정 → Kustomize 지원
- Argo CD는 디렉토리에 `kustomization.yaml` 있으면 자동 감지

---

## Phase 1: 나머지 디렉토리 전환

**목표:** workloads, hpa, security 디렉토리에 kustomization.yaml 추가

### Checklist
- [ ] `k8s/manifests/workloads/kustomization.yaml` 생성 (resources 리스트)
- [ ] `k8s/manifests/hpa/kustomization.yaml` 생성
- [ ] `k8s/manifests/security/kustomization.yaml` 생성
- [ ] 각 디렉토리의 Argo CD Application이 정상 sync되는지 확인

### 산출물 (예상)
- `k8s/manifests/workloads/kustomization.yaml`
- `k8s/manifests/hpa/kustomization.yaml`
- `k8s/manifests/security/kustomization.yaml`

---

## Phase 2: Argo CD Application 검증

**목표:** 전체 Kustomize 전환 후 Argo CD 동작 검증

### Checklist
- [ ] 4개 Application 모두 Healthy/Synced 상태 확인
- [ ] ConfigMap 변경 → Alloy pod 자동 rolling restart 확인
- [ ] prune 동작 확인 (이전 해시 ConfigMap 자동 삭제)
- [ ] selfHeal 동작 확인