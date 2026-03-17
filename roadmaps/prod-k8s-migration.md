# Prod K8s Migration Roadmap

> EC2 개별 인스턴스 기반 prod 인프라를 Multi-AZ kubeadm K8s 클러스터로 전환
>
> 트래킹 시작: 2026-03-14

---

## 진행 현황

| Phase | 제목 | 상태 | 완료일 | 비고 |
|:-----:|------|:----:|:-----:|------|
| 0 | [Staging K8s Lab 검증](#phase-0-staging-k8s-lab-검증) | ⏭ Skip | - | prod 직행, staging은 prod 완료 후 동기화 |
| 1 | [Prod 기존 인프라 보강](#phase-1-prod-기존-인프라-보강) | ✅ Done | 2026-03-14 | Redis/RabbitMQ apply 완료 |
| 2 | [K8s 부트스트랩 자동화 준비](#phase-2-k8s-부트스트랩-자동화-준비) | ✅ Done | 2026-03-14 | 스크립트 + 매니페스트 + provisioning spec |
| 3 | [Prod Base 멀티AZ 전환](#phase-3-prod-base-멀티az-전환) | ✅ Done | 2026-03-16 | 3AZ 서브넷 + NAT Ubuntu 전환 |
| 4 | [Prod App K8s 인프라 구성](#phase-4-prod-app-k8s-인프라-구성) | ✅ Done | 2026-03-16 | ALB path-based routing + 3AZ master HA |
| 5 | [K8s 클러스터 부트스트랩](#phase-5-k8s-클러스터-부트스트랩) | ✅ Done | 2026-03-17 | E2E 트래픽 확인 완료 |
| 6 | [Observability + ArgoCD](#phase-6-observability--argocd) | ✅ Done | 2026-03-17 | Ansible 자동화 포함 |
| 6.5 | [워크로드 안정화 + 재프로비저닝 준비](#phase-65-워크로드-안정화--재프로비저닝-준비) | 🔲 Todo | - | P0~P2 이슈 해결 |
| 7 | [트래픽 전환 + 기존 EC2 정리](#phase-7-트래픽-전환--기존-ec2-정리) | 🔲 Todo | - | 무중단 전환 |
| 8 | [멀티환경 재현 + 완전 자동화](#phase-8-멀티환경-재현--완전-자동화) | 🔲 Todo | - | Kustomize + Ansible 원클릭 |

---

## Phase 0: Staging K8s Lab 검증

**목표:** staging k8s-lab에서 chat/api 서비스가 K8s에서 정상 동작하는지 검증

### Checklist
- [x] kubeadm 클러스터 초기화 (Master 1 + Worker 2)
- [x] Calico CNI 설치 (VXLAN + BGP Disabled)
- [x] chat 서비스 배포 + ECR 인증 CronJob
- [x] NGINX Gateway Fabric + NLB 연결
- [x] api 서비스 배포 + Flyway 마이그레이션 성공
- [x] k8s-lab middleware EC2 Terraform plan (Redis + RabbitMQ)
- [ ] k8s-lab middleware apply + Redis/RabbitMQ 컨테이너 기동
- [ ] Parameter Store 값 업데이트 (10.2.27.240) 후 api 재기동
- [ ] api → Redis/RabbitMQ 연결 성공 확인
- [ ] chat DDL_AUTO를 `validate`로 변경 (Flyway 충돌 근본 해결)
- [ ] HPA 적용 + 부하 테스트로 오토스케일링 검증

### 산출물
- `terraform/environments/staging/k8s-lab/main.tf` — k8s-lab 인프라 (완료)
- `KTB_5_TEAM_WIKI/.../Kubeadm_Guide/01~11` — 가이드 문서 (지속 업데이트)
- `KTB_5_TEAM_WIKI/.../K8s_provisioning/01~07` — AI 실행용 provisioning spec (완료)

### 비고
- middleware 인스턴스(10.2.27.240) 부팅 확인 후 테스트 재개
- `SPRING_PROFILES_ACTIVE=staging`으로 변경 필요

---

## Phase 1: Prod 기존 인프라 보강

**목표:** K8s 전환 전에 prod/staging app 레이어에 Redis, RabbitMQ 개별 인스턴스 추가

### Checklist
- [x] staging/app에 redis + rabbitmq 서비스 추가 (plan: 6 add, 4 change)
- [x] prod/app에 redis + rabbitmq 서비스 추가 (plan: 6 add)
- [x] staging/app variables.tf에 instance_types 추가
- [x] prod/app DNS 레코드 추가 (redis.prod.doktori.internal, rabbitmq.prod.doktori.internal)
- [x] staging/app `terraform apply`
- [x] prod/app `terraform apply`

### 산출물
- `terraform/environments/staging/app/main.tf` — redis/rabbitmq 추가됨
- `terraform/environments/prod/app/main.tf` — redis/rabbitmq 추가됨

---

## Phase 2: K8s 부트스트랩 자동화 준비

**목표:** 프로덕션 K8s 클러스터를 원클릭으로 구성할 수 있는 스크립트 + 매니페스트 준비

### Checklist
- [x] `config.env` — 환경 설정 값 1곳에서 관리
- [x] `node-setup.sh` — 모든 노드: containerd + kubeadm + kubectl 설치
- [x] `cluster-init.sh` — master: kubeadm init + Calico + Helm + NGF
- [x] `deploy-workloads.sh` — ECR 인증 + Deployments + Services + Gateway + HTTPRoutes
- [x] `install-observability.sh` — metrics-server + kube-state-metrics + HPA + Alloy
- [x] `install-argocd.sh` — NetworkPolicy + ArgoCD (Helm)
- [x] Helm values: `helm/argocd-values.yaml`
- [x] 매니페스트: HPA, Alloy (RBAC + ConfigMap + DaemonSet), NetworkPolicy
- [x] K8s provisioning spec 06_observability.md 작성
- [x] K8s provisioning spec 07_argocd.md 작성

### 산출물
- `k8s/` 디렉토리 전체 — 부트스트랩 스크립트 + 매니페스트
- `K8s_provisioning/06_observability.md` — Helm 기반 모니터링 스펙
- `K8s_provisioning/07_argocd.md` — ArgoCD + 보안 스펙

---

## Phase 3: Prod Base 멀티AZ 전환

**목표:** prod VPC에 2c AZ 서브넷 추가, NAT 이중화. base 변경이므로 **별도 PR 필수** (CLAUDE.md 규칙)

### Checklist
- [x] networking 모듈에 3AZ 서브넷 추가 (public_b, private_app_b — ap-northeast-2b)
- [x] NAT 인스턴스 AMI를 Amazon Linux 2 → Ubuntu 22.04 전환
- [x] NAT 인스턴스 SSM IAM role + iptables 동적 인터페이스 감지
- [x] base outputs에 새 서브넷 ID 포함 확인
- [x] `./scripts/plan-all.sh` 전체 plan 통과
- [x] PR #30 생성

### 산출물
- `terraform/environments/prod/base/main.tf` — 3AZ 서브넷
- `terraform/modules/networking/main.tf` — NAT Ubuntu + SSM IAM

---

## Phase 4: Prod App K8s 인프라 구성

**목표:** Terraform으로 K8s master/worker ASG, ALB, Internal NLB, Frontend ASG 구성

### Checklist

### Checklist
- [x] K8s Master/Worker SG 생성 (apiserver, etcd, kubelet, VXLAN, NodePort)
- [x] K8s Master ASG: 3AZ × 1대 = 3대 (t4g.medium, HA control plane)
- [x] K8s Worker ASG: 4대 (t4g.large, 3AZ 분산)
- [x] Internal NLB 생성 (6443 control-plane + 30080 worker NodePort)
- [x] Frontend ALB + ASG (2AZ, t4g.small)
- [x] ALB path-based routing (/api/*, /ws/* → K8s workers, /ai/* → AI EC2)
- [x] user_data retry 로직 (follower join 5회 + cert-key 재조회)
- [x] Route53 internal DNS (k8s NLB, frontend ALB)
- [x] PR #30 생성

### 산출물
- `terraform/environments/prod/app/main.tf` — K8s + ALB routing
- `terraform/modules/k8s-cluster/` — Master/Worker ASG + NLB
- `terraform/modules/frontend/` — ALB + Frontend ASG

### 아키텍처
```
ALB (L7, public)
├── /api/*, /ws/*  → K8s Worker TG (30080) → NGF → api/chat Pod
├── /ai/*          → AI EC2 TG (8000)
└── /* (default)   → Frontend ASG TG (3000)

Internal NLB → Master 6443 (control-plane)
             → Worker 30080 (NGF NodePort)

K8s Masters (2a, 2b, 2c) — etcd HA, stacked
K8s Workers (3AZ × ~1-2) — NGF + workloads
AI EC2 (2a) — K8s 외부
Data (2a): RDS, Redis, RabbitMQ
```

---

## Phase 5: K8s 클러스터 부트스트랩

**목표:** Terraform apply 후 실제 K8s 클러스터 구성 (Phase 2 스크립트 활용)

### Checklist
- [x] Packer AMI로 containerd/kubeadm/kubelet 사전 설치
- [x] user_data 자동 부트스트랩 (kubeadm init + SSM join 정보 저장)
- [x] Master 3대 (3AZ) kubeadm HA — etcd quorum 정상
- [x] Worker 4대 (3AZ) join 완료
- [x] Calico CNI (VXLAN, BGP Disabled) 설치
- [x] Helm + Gateway API CRD + NGINX Gateway Fabric 설치
- [x] `deploy-workloads.sh` — ECR 인증, chat/api Deployment, Gateway, HTTPRoutes
- [x] api Flyway 마이그레이션 성공 확인
- [x] ALB → Worker NodePort → NGF → Pod E2E 트래픽 확인

### 산출물
- Running K8s 클러스터 (Master 3 + Worker 4, 3AZ HA)
- NGF NodePort 30080/30443 Ready

---

## Phase 6: Observability + ArgoCD

**목표:** 모니터링 연동 + GitOps 파이프라인 구성

### Checklist
- [x] `install-observability.sh` 실행 (metrics-server, kube-state-metrics, HPA, Alloy)
- [x] Grafana에서 `up{env="prod-k8s"}` 메트릭 수신 확인
- [x] Loki 로그 수신 확인 (prod + kube-system namespace)
- [x] `install-argocd.sh` 실행 (NetworkPolicy + ArgoCD Helm)
- [x] `setup-argocd.sh` — Git 저장소 연결 + Application 생성
- [x] ArgoCD auto-sync 검증 (chat 이미지 태그 변경 → 자동 배포 확인)
- [x] etcd Encryption at Rest 적용
- [x] kubelet 보안 강화 (마스터 완료, 워커는 Ansible 자동화로 적용 예정)
- [ ] CI 이미지 태그 자동화 → Phase 8로 이동
- [x] Ansible post-bootstrap playbook 구성

### 산출물
- `k8s/install-observability.sh` — 실행 완료
- `k8s/install-argocd.sh` — 실행 완료
- ArgoCD Application: Synced + Healthy

---

## Phase 6.5: 워크로드 안정화 + 재프로비저닝 준비

**목표:** 현재 워크로드의 P0~P2 이슈를 해결하여 트래픽 전환 전 안정성 확보 + 클러스터 재프로비저닝 시 자동 복구 가능하게

### P0 — 재프로비저닝 시 클러스터 깨짐

- [x] api/chat Deployment에 readinessProbe + livenessProbe + startupProbe 추가
- [x] ECR 인증 chicken-and-egg 해결: Ansible이 ECR Secret 생성 → manifest apply → ArgoCD 설치 순서 보장
- [x] ECR CronJob `base64 -w 0` → Alpine 호환 (`base64 | tr -d '\n'`)
- [x] topologySpreadConstraints: DoNotSchedule → ScheduleAnyway + AZ/node 2단계
- [x] deploy-workloads.sh vs ArgoCD 이중 관리 정리 (스크립트는 초기 1회용으로 명확화, 헤더 주석 추가)
- [x] 위키 프로비저닝 문서 ↔ 매니페스트 동기화 (probe 타이밍, topology, terminationGracePeriod, priorityClassName)

### P1 — 운영 안정성

- [x] api deployment `:latest` → 고정 태그 `5afb0d5`
- [x] chat CPU limits 추가 (cpu: 1, 위키 기준)
- [x] monitoring namespace를 Git manifests에 포함
- [x] Alloy `__ALLOY_VERSION__` → 실제 버전 v1.9.0으로 교체
- [x] api/chat securityContext 추가 (allowPrivilegeEscalation: false, readOnlyRootFilesystem: true + /tmp emptyDir)
- [x] monitoring namespace NetworkPolicy 추가 (default-deny + kube-state-metrics 허용)

### P2 — 개선 권장

- [ ] kubeadm join 토큰 만료 대응 (ASG 교체 시 자동 재발급)
- [ ] HPA scaleUp stabilization 값 통일
- [ ] SSM stale parameters cleanup 로직 (재프로비저닝 전 이전 클러스터 값 삭제)
- [ ] monitoring/ArgoCD PodDisruptionBudget 추가
- [ ] ArgoCD targetRevision을 main으로 통일 (현재 feature/terraform에서 작업 중)
- [ ] WebSocket idle timeout 조정 (1h → 적정값 검토)

### 산출물
- 수정된 매니페스트: `k8s/manifests/workloads/`, `k8s/manifests/hpa/`, `k8s/manifests/security/`
- Ansible role 업데이트: ECR 초기 인증, health probe 포함 매니페스트
- 재프로비저닝 테스트 통과 (destroy → recreate → E2E 확인)

### 비고
- P0은 Phase 7 전에 **필수** 완료
- P1은 트래픽 전환 전 권장
- P2는 Phase 8과 병행 가능

---

## Phase 7: 트래픽 전환 + 기존 EC2 정리

**목표:** 기존 EC2 기반 서비스에서 K8s로 무중단 전환

### Checklist
- [ ] K8s 환경에서 전체 서비스 E2E 테스트 통과
- [ ] DNS 전환: CloudFront origin을 ALB로 변경 (또는 weighted routing)
- [ ] 모니터링 서버에서 K8s 메트릭/로그 정상 수신 확인
- [ ] 기존 nginx, api, chat EC2 인스턴스 Stop (즉시 삭제 X)
- [ ] 1~2일 안정화 모니터링
- [ ] 안정 확인 후 기존 EC2 Terraform에서 제거 + destroy
- [ ] Route53 기존 DNS 레코드 정리
- [ ] 비용 비교 (EC2 개별 vs K8s 클러스터)

### 산출물
- 무중단 전환 완료
- 기존 EC2 리소스 정리

### 주의사항
- 롤백 계획 필수: K8s 문제 시 기존 EC2 재기동
- DNS TTL을 낮춰두고 전환 (300초 → 60초)
- 전환 중 모니터링 서버 Grafana DNS Cutover 대시보드 활용

---

## Phase 8: 멀티환경 재현 + 완전 자동화

**목표:** dev/staging도 K8s로 전환하고, Kustomize + Ansible로 환경별 원클릭 재현 가능하게

### Checklist
- [ ] Kustomize 도입: base manifest + overlays/dev, overlays/prod 분리
- [ ] CI 이미지 태그 자동화: `kustomize edit set image` → ArgoCD auto-sync
- [ ] Ansible 완전 자동화: user_data에 bootstrap 스크립트 체이닝 (cluster-init → Ansible 트리거)
- [ ] kubelet hardening을 Packer AMI에 포함 (새 노드 자동 적용)
- [ ] 시크릿(Git PAT 등) SSM Parameter Store 저장 → Ansible이 자동 조회
- [ ] dev 환경 K8s 클러스터 구성 (Kustomize overlay로 리소스/replica 차등)
- [ ] `terraform apply` + ASG 기동만으로 전체 클러스터 프로비저닝 재현 검증

### 산출물
- `k8s/manifests/base/` + `k8s/manifests/overlays/{dev,prod}/`
- Ansible playbook 1회 실행으로 전체 환경 구성
- 클러스터 destroy → recreate 재현 테스트 통과