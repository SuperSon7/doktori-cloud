# K8s 부트스트랩 안정화 + ArgoCD 관리 통일 Roadmap

> 새 AWS 계정 이관 전 부트스트랩 자동화 완성 및 리소스 관리 소유권 통일
>
> 트래킹 시작: 2026-03-22

---

## 진행 현황

| Phase | 제목 | 상태 | 완료일 | 비고 |
|:-----:|------|:----:|:-----:|------|
| 0 | [인프라 긴급 수정](#phase-0-인프라-긴급-수정) | ✅ Done | 2026-03-21 | metrics-server, KSM, SG, NetPol |
| 1 | [ArgoCD 리소스 관리 통일](#phase-1-argocd-리소스-관리-통일) | 🔲 Todo | - | KSM Helm App 전환, raw manifest 제거 |
| 2 | [워크로드 정리](#phase-2-워크로드-정리) | 🔲 Todo | - | ECR CronJob/imagePullSecrets 제거 |
| 3 | [NetworkPolicy 완성](#phase-3-networkpolicy-완성) | 🔲 Todo | - | external-secrets ns, NGF 패치 자동화 |
| 4 | [Ansible 부트스트랩 변수화](#phase-4-ansible-부트스트랩-변수화) | 🔲 Todo | - | 하드코딩 제거, 새 계정 대응 |
| 5 | [부트스트랩 E2E 검증](#phase-5-부트스트랩-e2e-검증) | 🔲 Todo | - | staging에서 풀 부트스트랩 테스트 |

---

## Phase 0: 인프라 긴급 수정

**목표:** 클러스터 정상 운영 상태 복구 (HPA, 메트릭, 로그인)

### Checklist
- [x] metrics-server Helm 설치 → `kubectl top` 정상화
- [x] kube-state-metrics egress NetworkPolicy 추가 (PR #71)
- [x] 워커 SG에 워커→워커 kubelet(10250) 인바운드 허용 (PR #72)
- [x] api/chat Pod 외부 HTTPS(443) egress 허용 — 카카오 OAuth, Firebase FCM (PR #73)
- [x] HPA maxReplicas 4→8 변경
- [x] ArgoCD Helm App 정의 파일 커밋 (PR #76)

### 산출물
- `k8s/manifests/argocd/apps/metrics-server.yaml` — ArgoCD Helm App ✅
- `k8s/manifests/argocd/apps/kube-state-metrics.yaml` — ArgoCD Helm App ✅
- `ansible/roles/k8s-post-bootstrap/tasks/fetch-secrets.yml` — SSM fetch ✅
- `terraform/modules/k8s-cluster/main.tf` — worker_kubelet_from_self 룰 ✅

---

## Phase 1: ArgoCD 리소스 관리 통일

**목표:** "하나의 리소스, 하나의 소유자" 원칙 적용 — Helm standalone은 CNI+ArgoCD만, 나머지는 ArgoCD 관리

### Checklist
- [ ] `k8s/manifests/monitoring/kube-state-metrics.yaml` 삭제 (ArgoCD Helm App으로 전환)
- [ ] ArgoCD root-app이 `apps/kube-state-metrics.yaml`, `apps/metrics-server.yaml` 감지하는지 확인
- [ ] 현재 Helm standalone으로 설치된 metrics-server를 ArgoCD Helm App이 인계하도록 전환
- [ ] `install-observability.sh`에서 metrics-server/KSM Helm 설치 부분이 긴급복구 전용임을 확인 (이미 수정됨)

### 산출물
- `k8s/manifests/monitoring/kube-state-metrics.yaml` — 삭제
- ArgoCD UI에서 metrics-server, kube-state-metrics Application 정상 표시

---

## Phase 2: 워크로드 정리

**목표:** kubelet credential provider로 ECR 인증 통일, 불필요한 CronJob/imagePullSecrets 제거

### Checklist
- [ ] `k8s/manifests/workloads/ecr-cronjob.yaml` 삭제 (credential provider가 대체)
- [ ] api-deployment.yaml에서 `imagePullSecrets` 제거
- [ ] chat-deployment.yaml에서 `imagePullSecrets` 제거
- [ ] ECR credential provider가 전 워커 노드에 설치되었는지 확인 (4번째 워커 미조인 상태)
- [ ] user_data 스크립트에 ECR credential provider 설치 추가 (신규 노드 자동 적용)

### 산출물
- `k8s/manifests/workloads/ecr-cronjob.yaml` — 삭제
- `k8s/manifests/workloads/api-deployment.yaml` — imagePullSecrets 제거
- `k8s/manifests/workloads/chat-deployment.yaml` — imagePullSecrets 제거

---

## Phase 3: NetworkPolicy 완성

**목표:** 모든 네임스페이스에 빠짐없이 NetworkPolicy 적용, NGF 패치 자동화

### Checklist
- [ ] external-secrets 네임스페이스 NetworkPolicy 추가 (현재 수동 적용만 됨, Git에 없음)
- [ ] NGF externalTrafficPolicy: Cluster 패치를 Helm values 또는 post-install 스크립트로 영속화
- [ ] default-deny-egress 적용 네임스페이스 전수 점검 (argocd, nginx-gateway, chaos-testing 등)

### 산출물
- `k8s/manifests/security/netpol-all.yaml` — external-secrets ns 정책 추가
- NGF Helm values 또는 `k8s/bootstrap-argocd.sh`에 패치 반영

---

## Phase 4: Ansible 부트스트랩 변수화

**목표:** 새 AWS 계정 이관 시 config만 바꾸면 부트스트랩 가능하도록 하드코딩 제거

### Checklist
- [ ] AWS 계정 ID(250857930609) → 변수화 (`aws_account_id`)
  - `defaults/main.yml`, `api/chat-deployment.yaml`, `ecr-cronjob.yaml`, `config.env`
- [ ] VPC CIDR(10.1.0.0/16) → 변수화 (`vpc_cidr`)
  - `netpol-all.yaml` 15곳
- [ ] 모니터링 서버 FQDN(monitoring.mgmt.doktori.internal) → 변수화
  - `alloy-configmap.yaml`, `defaults/main.yml`, `config.env`
- [ ] 리전(ap-northeast-2) 하드코딩 정리
- [ ] ECR credential provider arch(arm64) → 변수화 (x86 대응)
- [ ] `k8s-site.yml`에 ECR credential provider 태스크 include 추가
- [ ] Ansible 실행 순서 수정: NetworkPolicy → ECR provider → 워크로드 → ArgoCD

### 산출물
- `ansible/roles/k8s-post-bootstrap/defaults/main.yml` — 변수 추가
- `k8s/config.env` — 변수 참조로 전환
- `ansible/k8s-site.yml` — 태스크 순서 수정

---

## Phase 5: 부트스트랩 E2E 검증

**목표:** staging 환경에서 처음부터 끝까지 부트스트랩 실행하여 문제 없음 확인

### Checklist
- [ ] staging Terraform apply (VPC, EC2, SG)
- [ ] `ansible/generate-inventory.sh` 실행 → 인벤토리 생성 확인
- [ ] `ansible-playbook k8s-site.yml` 실행 → 전 태스크 성공
- [ ] ArgoCD root-app sync → 모든 Application Healthy
- [ ] `kubectl top nodes/pods` 정상
- [ ] HPA 동작 확인 (TARGETS에 CPU % 표시)
- [ ] 카카오 로그인 정상
- [ ] ECR image pull 정상 (credential provider)

### 산출물
- staging 클러스터 정상 운영 확인 스크린샷/로그