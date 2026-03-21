# Disaster Recovery 런북

> 최종 갱신: 2026-03-21

---

## RTO/RPO 목표

| 컴포넌트 | RTO (목표 복구 시간) | RPO (허용 데이터 손실) | 근거 |
|----------|---------------------|----------------------|------|
| K8s 클러스터 | ~20분 | 0 (GitOps) | Ansible bootstrap + ArgoCD sync |
| RDS MySQL | ~15분 | ~5분 | 자동 백업 + Point-in-Time Recovery |
| Redis | ~5분 | ~1초 | Sentinel failover + AOF appendfsync everysec |
| RabbitMQ | ~5분 | 0 (Quorum Queue) | Raft 합의 완료된 메시지는 보존 |
| DNS | ~5분 | 0 | Route53 managed, Terraform으로 재생성 |
| 전체 서비스 | **~30분** | **~5분 (DB 기준)** | 병렬 복구 시 |

---

## 장애 심각도 분류

### SEV-1: 단일 노드 장애
- **증상**: Worker/Master 1대 다운, 파드 일부 재스케줄링
- **자동 복구**: ASG가 새 인스턴스 시작 → kubeadm join → 파드 재배치
- **예상 복구**: 5분 (자동)
- **수동 개입**: 불필요 (모니터링만)

### SEV-2: AZ 장애
- **증상**: 특정 AZ의 노드 전체 다운, 해당 AZ의 RDS 접근 불가
- **영향**: 파드는 다른 AZ로 재스케줄링되지만 RDS가 단일 AZ이면 DB 단절
- **예상 복구**: 15~20분 (RDS 복구 필요)
- **수동 개입**: 필요

### SEV-3: 클러스터 전체 장애
- **증상**: 모든 K8s 노드 다운 또는 etcd 쿼럼 상실
- **영향**: 서비스 완전 중단
- **예상 복구**: 20~30분 (전체 재부트스트랩)
- **수동 개입**: 필요

### SEV-4: 리전 장애
- **증상**: ap-northeast-2 전체 장애
- **영향**: 모든 서비스 완전 중단, 크로스 리전 DR 없음
- **대응**: AWS 리전 복구 대기 (SLA 기반)
- **장기 계획**: 크로스 리전 DR 구축 검토

---

## 복구 절차

### SEV-1: 단일 노드 장애

**자동 복구 확인만 하면 됨:**

```bash
# 1. 노드 상태 확인
kubectl get nodes

# 2. ASG에서 새 인스턴스 시작 확인
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*k8s*" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].[InstanceId,LaunchTime,PrivateIpAddress]" \
  --output table

# 3. 파드 재스케줄링 확인
kubectl get pods -n prod -o wide

# 4. HPA 상태 확인
kubectl get hpa -n prod
```

**Master 노드 장애 시 추가 확인:**
```bash
# etcd 클러스터 상태 (다른 master에서)
sudo ETCDCTL_API=3 etcdctl member list \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

---

### SEV-2: AZ 장애

**1단계: 상태 파악**
```bash
# 어떤 AZ가 영향받는지 확인
kubectl get nodes -o custom-columns=NAME:.metadata.name,AZ:.metadata.labels.topology\\.kubernetes\\.io/zone,STATUS:.status.conditions[-1].type

# 영향받는 파드 확인
kubectl get pods -n prod -o wide | grep -v Running
```

**2단계: RDS 복구 (단일 AZ인 경우)**
```bash
# RDS 상태 확인
aws rds describe-db-instances \
  --db-instance-identifier doktori-prod-mysql \
  --query "DBInstances[0].[DBInstanceStatus,AvailabilityZone]"

# Point-in-Time Recovery로 다른 AZ에 복원
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier doktori-prod-mysql \
  --target-db-instance-identifier doktori-prod-mysql-recovery \
  --restore-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --availability-zone ap-northeast-2c \
  --db-subnet-group-name <기존-서브넷-그룹>

# 복원 후 DNS CNAME 업데이트 (Route53)
# db.doktori.internal → 새 RDS 엔드포인트
```

**3단계: Data HA 확인**
```bash
# Redis Sentinel 상태
aws ssm send-command --instance-ids <data-ha-instance> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["redis-cli -p 26379 sentinel masters"]'

# RabbitMQ 클러스터 상태
aws ssm send-command --instance-ids <data-ha-instance> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["rabbitmqctl cluster_status"]'
```

---

### SEV-3: 클러스터 전체 재부트스트랩

**복구 우선순위:**
```
1. 네트워크 (DNS + NAT)     → Terraform 확인
2. 데이터베이스 (RDS)        → 자동 백업에서 복원
3. K8s 클러스터              → Ansible bootstrap
4. ArgoCD + 워크로드         → ArgoCD auto-sync
5. Data HA (Redis/RabbitMQ)  → ASG 자동 복구
6. Observability             → ArgoCD sync
```

**1단계: 인프라 확인/복구**
```bash
# Terraform으로 인프라 상태 확인
cd terraform/environments/prod/base
terraform plan  # 변경사항 없어야 함

cd ../app
terraform plan  # ASG/NLB 상태 확인

# 필요 시 재적용
terraform apply
```

**2단계: K8s 클러스터 부트스트랩**
```bash
# inventory 생성 (ASG에서 새 인스턴스 감지)
cd ansible
./generate-inventory.sh

# 전체 부트스트랩 (one-shot)
# SSM에서 시크릿 자동 fetch → 수동 입력 불필요
ansible-playbook -i inventory/k8s-hosts.yml k8s-site.yml
```

**수동 부트스트랩 (Ansible 불가 시):**
```bash
# Master SSM 접속
aws ssm start-session --target <master-instance-id>

# 순차 실행
sudo bash k8s/cluster-init.sh       # kubeadm init + Calico + NGF
# Worker join (각 worker에서)
sudo kubeadm join <NLB_DNS>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>

# 워크로드 + 모니터링 + ArgoCD
bash k8s/deploy-workloads.sh
bash k8s/install-observability.sh
bash k8s/bootstrap-argocd.sh        # SSM에서 PAT 자동 fetch
```

**3단계: ArgoCD sync 확인**
```bash
# ArgoCD Application 상태 확인
kubectl get application -n argocd

# 전체 Synced + Healthy 확인
# workloads, hpa, monitoring, security 4개
```

**4단계: 서비스 검증**
```bash
# API health
curl http://<NLB_DNS>/api/health

# Chat health
curl http://<NLB_DNS>/api/chat/health

# 파드 상태
kubectl get pods -n prod -o wide

# HPA 동작 확인
kubectl get hpa -n prod

# 메트릭 수집 확인 (Alloy → Prometheus)
kubectl logs -n monitoring -l app=alloy --tail=20
```

---

## 검증 체크리스트

### 인프라
- [ ] 모든 EC2 인스턴스 Running (Master 3, Worker 4)
- [ ] NLB 헬스체크 통과
- [ ] NAT 인스턴스 2개 정상
- [ ] RDS 접속 가능 (`db.doktori.internal:3306`)

### K8s
- [ ] 모든 노드 Ready (`kubectl get nodes`)
- [ ] CoreDNS 동작 (`kubectl get pods -n kube-system`)
- [ ] Calico CNI 정상 (`kubectl get pods -n calico-system`)
- [ ] NGINX Gateway Fabric 정상 (`kubectl get pods -n nginx-gateway`)
- [ ] metrics-server 동작 (`kubectl top nodes`)

### 워크로드
- [ ] API 파드 2+ Running (`kubectl get pods -n prod -l component=api`)
- [ ] Chat 파드 2+ Running (`kubectl get pods -n prod -l component=chat`)
- [ ] HPA 동작 (`kubectl get hpa -n prod` — TARGETS에 % 표시)
- [ ] PDB 적용 (`kubectl get pdb -n prod`)
- [ ] Health check 통과 (`curl /api/health`)

### ArgoCD
- [ ] 4개 Application 모두 Synced + Healthy
- [ ] Git 저장소 연결 정상 (`kubectl get secret private-repo-creds -n argocd`)

### Data Layer
- [ ] Redis Sentinel 정상 (master 1 + replica 2)
- [ ] RabbitMQ Quorum 정상 (3노드)
- [ ] DNS 리졸브 정상 (`redis.doktori.internal`, `rabbitmq.doktori.internal`)

### Observability
- [ ] Alloy DaemonSet 전체 노드 Running
- [ ] Prometheus에 메트릭 도착 (Grafana 대시보드 확인)
- [ ] Loki에 로그 도착
- [ ] Alert rules 로드됨

### 보안
- [ ] NetworkPolicy 적용 (`kubectl get netpol -A`)
- [ ] etcd encryption 활성화
- [ ] kubelet anonymous auth 비활성화

---

## 커뮤니케이션 템플릿

### 장애 발생 시 (Discord)
```
🚨 [SEV-{N}] {컴포넌트} 장애 발생
- 시간: YYYY-MM-DD HH:MM KST
- 영향: {사용자 영향 설명}
- 상태: 조사 중 / 복구 중
- 담당: @{담당자}
- 예상 복구: ~{N}분
```

### 복구 완료 시
```
✅ [SEV-{N}] {컴포넌트} 복구 완료
- 장애 시간: HH:MM ~ HH:MM KST ({N}분)
- 원인: {간단한 원인}
- 조치: {수행한 조치}
- 후속: 포스트모텀 예정
```

---

## etcd 백업이 필요 없는 이유

| 데이터 | 복구 방법 | etcd 백업 필요? |
|--------|----------|---------------|
| Deployments, Services, HPA 등 | Git → ArgoCD auto-sync | ❌ |
| NetworkPolicy, PDB | Git → ArgoCD auto-sync | ❌ |
| ECR credentials | `deploy-workloads.sh`가 재생성 | ❌ |
| Firebase credentials | SSM Parameter Store에서 fetch | ❌ |
| ArgoCD Git PAT | SSM Parameter Store에서 fetch | ❌ |
| etcd encryption key | 새로 생성 (GitOps이므로 기존 데이터 복원 불필요) | ❌ |

**GitOps + SSM = etcd 백업 없이 완전 복구 가능**