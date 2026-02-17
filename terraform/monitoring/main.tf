# =============================================================================
# Doktori Monitoring Server
# =============================================================================
#
# 단일 인스턴스로 prod / staging / dev 전체 환경 관측
#
# 스택: Prometheus + Loki + Grafana + Blackbox Exporter (Docker Compose)
# 설정: Cloud/monitoring/ 참조
#
# ─── 디스크 산정 ───
# Prometheus (30일, ~4K series)  : ~1.3 GB
# Loki (30일, 압축 후)           : ~1-2 GB
# Grafana + 플러그인              : ~0.3 GB
# Docker 이미지                  : ~2 GB
# OS                             : ~4 GB
# 합계 ~9.6 GB × 2 (안전 마진)   = ~20 GB → 여유분 포함 30 GB
#
# ─── 인스턴스 타입 ───
# t4g.medium (4 GB RAM) 선택 이유:
#   - Prometheus + Loki + Grafana 동시 구동 시 메모리 ~1.8-3.2 GB 사용
#   - t4g.small (2 GB) → 쿼리 스파이크 시 OOM 위험
#   - t4g.medium → 쿼리 버스트 + OS 페이지 캐시 여유
#   - ARM(Graviton) → 동급 x86 대비 ~20% 비용 절감
#
# ─── 서브넷 배치: 퍼블릭 + SG 강화 ───
# 프라이빗 서브넷 고려했으나 현재 부적합:
#   - Prometheus가 doktori.kr / dev.doktori.kr HTTPS로 외부 스크레이프
#   - dev/prod VPC CIDR 동일 (10.0.0.0/16) → VPC 피어링 불가
#   - 프라이빗 배치 시 NAT 필요 (~$32/월 추가)
# 대안: 퍼블릭 서브넷 + SG 강화 + WireGuard VPN으로 Grafana 접근 제한
# 향후 VPN 구성 완료 시 → Grafana/Prometheus SG를 VPN CIDR만 허용으로 전환
#
# =============================================================================

# -----------------------------------------------------------------------------
# Default VPC
# -----------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# -----------------------------------------------------------------------------
# AMI - 아키텍처 변경 시 variable만 수정하면 자동 전환
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = [var.architecture == "arm64"
      ? "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"
      : "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
    ]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# IAM Role (SSM 접근)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "monitoring" {
  name = "${var.project_name}-monitoring-ec2-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.project_name}-monitoring-ec2-ssm" }
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.project_name}-monitoring-profile"
  role = aws_iam_role.monitoring.name
}

# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------
resource "aws_security_group" "monitoring" {
  name        = "${var.project_name}-monitoring-sg"
  description = "Monitoring server - Prometheus, Loki, Grafana"
  vpc_id      = data.aws_vpc.default.id

  # SSH - 관리자 IP만
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_admin_cidrs
  }

  # WireGuard VPN
  ingress {
    description = "WireGuard VPN"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Grafana - 관리자만 (향후 VPN CIDR로 전환)
  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.allowed_admin_cidrs
  }

  # Prometheus - 관리자만
  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = var.allowed_admin_cidrs
  }

  # Alertmanager - 관리자만
  ingress {
    description = "Alertmanager"
    from_port   = 9093
    to_port     = 9093
    protocol    = "tcp"
    cidr_blocks = var.allowed_admin_cidrs
  }

  # Loki - 타겟 서버(prod/dev)에서 로그 push
  ingress {
    description = "Loki from targets"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = var.target_server_cidrs
  }

  # Prometheus remote_write - Alloy에서 메트릭 push (Phase 1)
  ingress {
    description = "Prometheus remote_write from Alloy"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = var.target_server_cidrs
  }

  # Alloy UI (디버깅용, 관리자만)
  ingress {
    description = "Alloy UI"
    from_port   = 12345
    to_port     = 12345
    protocol    = "tcp"
    cidr_blocks = var.allowed_admin_cidrs
  }

  # Outbound - 전부 허용 (HTTPS 스크레이프, Docker pull 등)
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-monitoring-sg"
    Service = "monitoring"
  }
}

# -----------------------------------------------------------------------------
# EC2 Instance
# -----------------------------------------------------------------------------
resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.monitoring.id]
  iam_instance_profile   = aws_iam_instance_profile.monitoring.name

  metadata_options {
    http_tokens   = "required" # IMDSv2 강제
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name         = "${var.project_name}-monitoring"
    Service      = "monitoring"
    Architecture = var.architecture
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

# -----------------------------------------------------------------------------
# Elastic IP - 타겟 서버 SG/설정에서 이 IP를 참조
# -----------------------------------------------------------------------------
resource "aws_eip" "monitoring" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-monitoring-eip"
  }
}

resource "aws_eip_association" "monitoring" {
  allocation_id = aws_eip.monitoring.id
  instance_id   = aws_instance.monitoring.id
}