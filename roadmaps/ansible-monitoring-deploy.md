# Ansible 기반 Monitoring 배포 자동화 로드맵

> 현재: SSM 수동 배포 → 목표: Ansible docker-compose 기반 자동화

---

## 현황 (2026-04-03)

- Ansible role 존재하지만 systemd binary 설치 방식 (실제 운영과 불일치)
- 실제 운영: `monitoring/docker-compose.yml` + 수동 SCP
- inventory.ini IP 구버전 (이전 계정 서버)
- SSH 키 하드코딩 → SSM 방식으로 전환 필요

---

## Phase 1 — Ansible 기초 + 현행화

- [ ] Ansible 기본 개념 학습 (inventory, playbook, role, vars)
- [ ] `inventory.ini` 현행화 — 새 monitoring EC2 IP/instance-id로 교체
- [ ] SSH → SSM 연결 방식 전환
  ```ini
  [monitoring_server]
  monitor_node ansible_connection=community.aws.aws_ssm ansible_aws_ssm_instance_id=i-xxxx
  ```
- [ ] `group_vars/monitoring_server.yml` 생성 — 서버별 변수 분리

## Phase 2 — Role 재작성 (docker-compose 기반)

- [ ] `roles/monitoring/tasks/main.yml` 재작성
  - Docker + Docker Compose 설치 확인
  - `monitoring/` 디렉토리 전송 (`synchronize` 또는 `copy` 모듈)
  - `.env` 파일 템플릿 생성
  - `docker compose up -d` 실행
- [ ] `roles/monitoring/templates/` 정리
  - `loki-config.yml.j2` → `monitoring/loki/loki-config.yml`로 통합 or 제거
  - `prometheus.yml.j2` → 동일
- [ ] Loki 저장소 경로 수정 (`/tmp/loki` → `/home/ubuntu/monitoring/loki-data`)

## Phase 3 — 변수화 + 재사용성

- [ ] 버전 변수화 (`prometheus_version`, `loki_version`, `grafana_version`)
- [ ] 환경별 변수 분리 (`group_vars/monitoring_server.yml`)
- [ ] idempotent 보장 — 중복 실행해도 안전하게

## Phase 4 — ECR 기반 이미지 관리

> 현재: Docker Hub에서 직접 pull (rate limit, 보안 검증 없음)
> 목표: CI/CD → ECR → EC2 IAM role pull

- [ ] CI/CD 파이프라인 구성 (GitHub Actions)
  - 공식 이미지 pull (prometheus, grafana, loki, cadvisor 등)
  - Trivy로 보안 스캔
  - ECR push
- [ ] docker-compose.yml 이미지 주소를 ECR URI로 교체
- [ ] monitoring EC2 IAM role에 ECR pull 권한 추가
  ```hcl
  # monitoring/app/main.tf
  resource "aws_iam_role_policy_attachment" "ecr_read" {
    role       = aws_iam_role.monitoring.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  }
  ```
- [ ] `docker login`을 `aws ecr get-login-password | docker login` 으로 대체 (자동화)

## Phase 5 — agent role 정합성

- [ ] `roles/agent/` — Alloy 기반으로 재작성 (현재 Node Exporter + Promtail → K8s는 Alloy 사용)
- [ ] `generate-inventory.sh` — monitoring_server도 AWS 태그 기반 자동 생성으로 통합

---

## 참고
- [Ansible aws_ssm connection plugin](https://docs.ansible.com/ansible/latest/collections/community/aws/aws_ssm_connection.html)
- [Ansible docker_compose module](https://docs.ansible.com/ansible/latest/collections/community/docker/docker_compose_v2_module.html)
