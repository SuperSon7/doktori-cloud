# =============================================================================
# Monitoring App — Compute 레이어
# EC2, IAM, SG, PHZ record
# SG를 base가 아닌 app에 두는 이유:
#   - 서비스 포트 변경이 잦아 compute와 함께 관리하는 것이 자연스러움
# EIP 없음: EC2가 private 서브넷에 있으므로 불필요. 아웃바운드는 NAT, 인바운드는 VPN 경유.
# =============================================================================

# -----------------------------------------------------------------------------
# Remote State — 상위 레이어 참조 (인프라 식별자는 remote_state로 직접 참조)
# -----------------------------------------------------------------------------
data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = "doktori-terraform-state"
    key    = "monitoring/base/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

data "terraform_remote_state" "data" {
  backend = "s3"
  config = {
    bucket = "doktori-terraform-state"
    key    = "monitoring/data/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

locals {
  base = data.terraform_remote_state.base.outputs
  data = data.terraform_remote_state.data.outputs
}

data "aws_route53_zone" "mgmt" {
  name         = local.base.mgmt_zone_name
  private_zone = true
}

# -----------------------------------------------------------------------------
# AMI — 아키텍처 변경 시 variable만 수정하면 자동 전환
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name = "name"
    values = [var.architecture == "arm64"
      ? "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"
    : "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------
resource "aws_security_group" "monitoring" {
  name        = "${var.project_name}-monitoring-sg"
  description = "Monitoring server SG"
  vpc_id      = local.base.vpc_id

  # Prometheus scrape (9090): 피어링된 환경 VPC에서만 허용
  ingress {
    description = "Prometheus scrape from peered VPCs"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = var.peered_vpc_cidrs
  }

  # Grafana (3000): 관리자 IP에서만 허용
  ingress {
    description = "Grafana from admin IPs"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.allowed_admin_cidrs
  }

  # Loki (3100): 피어링된 환경 VPC에서만 허용
  ingress {
    description = "Loki push from peered VPCs"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = var.peered_vpc_cidrs
  }

  # Prometheus remote_write target: 피어링된 환경 VPC에서만 허용
  ingress {
    description = "Prometheus remote_write from peered VPCs"
    from_port   = 9091
    to_port     = 9091
    protocol    = "tcp"
    cidr_blocks = var.peered_vpc_cidrs
  }

  egress {
    description = "Allow all outbound (Prometheus HTTPS scrape, apt, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-monitoring-sg"
    Service = "monitoring"
  }

  lifecycle {
    create_before_destroy = true
  }
}


# -----------------------------------------------------------------------------
# IAM Role (SSM + Loki S3 + CloudWatch)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "monitoring" {
  name = "${var.project_name}-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.project_name}-monitoring-role" }
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.project_name}-monitoring-profile"
  role = aws_iam_role.monitoring.name
}

resource "aws_iam_role_policy" "loki_s3" {
  name = "${var.project_name}-monitoring-loki-s3"
  role = aws_iam_role.monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ]
      Resource = [
        local.data.loki_bucket_arn,
        "${local.data.loki_bucket_arn}/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "cloudwatch_read" {
  name = "${var.project_name}-monitoring-cloudwatch-read"
  role = aws_iam_role.monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListMetrics",
        "cloudwatch:DescribeAlarms"
      ]
      Resource = "*"
    }]
  })
}

# -----------------------------------------------------------------------------
# EC2 Instance
# -----------------------------------------------------------------------------
resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = local.base.private_subnet_id
  vpc_security_group_ids = [aws_security_group.monitoring.id]
  iam_instance_profile   = aws_iam_instance_profile.monitoring.name

  user_data = templatefile("${path.module}/scripts/user_data.sh", {
    project_name = var.project_name
    architecture = var.architecture
  })

  metadata_options {
    http_tokens                 = "required" # IMDSv2 강제
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2 # Docker 컨테이너 → IMDS 접근 허용
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name    = "${var.project_name}-monitoring"
    Service = "monitoring"
    Owner   = "cloud"
  }

  lifecycle {
    # AMI ID는 most_recent로 매번 달라지므로 apply 시 재생성 방지
    ignore_changes = [ami]
  }
}


# -----------------------------------------------------------------------------
# PHZ Record — monitoring.mgmt.doktori.internal
# -----------------------------------------------------------------------------
resource "aws_route53_record" "monitoring" {
  zone_id = data.aws_route53_zone.mgmt.zone_id
  name    = "monitoring.${data.aws_route53_zone.mgmt.name}"
  type    = "A"
  ttl     = 300
  records = [aws_instance.monitoring.private_ip]
}
