# Doktori Ansible Automation

## Playbooks

### 1. Monitoring Setup (기존)

모니터링 서버 + 에이전트(Promtail/Node Exporter) 설정.

```bash
ansible-playbook -i inventory.ini playbook.yml
```

### 2. K8s Post-Bootstrap (신규)

K8s 클러스터 Ready 후 워크로드/Observability/ArgoCD/보안을 자동 프로비저닝.

**Why Ansible?**
- 기존 6개 스크립트를 수동으로 순서대로 실행하던 것을 자동화
- 멱등성 보장 (재실행해도 안전)
- 멀티노드 동시 실행 (kubelet hardening을 전체 워커에 한번에)
- SSM connection plugin으로 private subnet 인스턴스에 직접 접근

**구조:**
```
ansible/
├── k8s-site.yml                      # K8s post-bootstrap playbook
├── generate-inventory.sh             # AWS 태그 기반 inventory 자동 생성
├── roles/
│   └── k8s-post-bootstrap/
│       ├── defaults/main.yml         # 기본 변수
│       └── tasks/
│           ├── main.yml              # 오케스트레이션
│           ├── workloads.yml         # ECR + Deployments + Gateway
│           ├── observability.yml     # metrics-server + Alloy + HPA
│           ├── argocd.yml            # ArgoCD + Git 연결
│           └── hardening.yml         # etcd 암호화 + kubelet 보안
```

**Prerequisites:**
```bash
pip install ansible boto3 botocore
ansible-galaxy collection install community.aws
```

**Usage:**
```bash
cd ansible

# 1. inventory 생성 (AWS 태그 기반)
./generate-inventory.sh

# 2. 전체 실행
ansible-playbook -i inventory/k8s-hosts.yml k8s-site.yml \
  -e git_repo_url=https://github.com/100-hours-a-week/5-team-service-cloud.git \
  -e git_username=SuperSon7 \
  -e git_pat=ghp_xxxxx

# 3. 특정 단계만
ansible-playbook -i inventory/k8s-hosts.yml k8s-site.yml --tags workloads
ansible-playbook -i inventory/k8s-hosts.yml k8s-site.yml --tags observability
ansible-playbook -i inventory/k8s-hosts.yml k8s-site.yml --tags argocd
ansible-playbook -i inventory/k8s-hosts.yml k8s-site.yml --tags hardening
```

**역할 분담:**

| 단계 | 도구 | 이유 |
|------|------|------|
| 인프라 (VPC, ASG, NLB) | Terraform | 선언적 인프라 관리 |
| AMI (containerd, kubeadm) | Packer | 이미지 빌드 |
| kubeadm init + CNI + NGF | user_data | ASG 교체 시 자동 실행 필요 |
| 워크로드 + Obs + ArgoCD + 보안 | **Ansible** | 클러스터 Ready 후 실행, 멱등성 필요 |
