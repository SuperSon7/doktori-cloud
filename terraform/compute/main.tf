# -----------------------------------------------------------------------------
# Remote State: Networking
# -----------------------------------------------------------------------------
data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = "doktori-terraform-state"
    key    = "networking/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# -----------------------------------------------------------------------------
# Security Group for EC2 Instance
# -----------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${var.project_name}-${local.environment}-app-sg"
  description = "Security group for application server"
  vpc_id      = data.terraform_remote_state.networking.outputs.vpc_id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = concat(var.allowed_admin_cidrs, ["0.0.0.0/0"])
  }

  # HTTP
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # WireGuard VPN
  ingress {
    description = "WireGuard VPN"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # AI Service
  ingress {
    description = "AI Service"
    from_port   = var.ai_port
    to_port     = var.ai_port
    protocol    = "tcp"
    cidr_blocks = var.allowed_admin_cidrs
  }

  # AI Service (8001)
  ingress {
    from_port   = 8001
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["211.244.225.166/32"]
  }

  # Spring Boot Blue (monitoring access)
  ingress {
    description = "Spring Boot (Blue)"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.monitoring_server_ips
  }

  # Spring Boot Green (monitoring access)
  ingress {
    description = "Spring Boot (Green)"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = var.monitoring_server_ips
  }

  # Grafana (Monitoring)
  ingress {
    description = "Grafana (Monitoring)"
    from_port   = 3003
    to_port     = 3003
    protocol    = "tcp"
    cidr_blocks = concat(var.allowed_admin_cidrs, ["122.40.177.81/32"])
  }

  # Prometheus (Monitoring)
  ingress {
    description = "Prometheus (Monitoring)"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = var.allowed_admin_cidrs
  }

  # Loki (Log aggregation)
  ingress {
    description = "Loki"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = ["211.244.225.166/32"]
  }

  # Promtail (Log shipping)
  ingress {
    description = "Promtail"
    from_port   = 9080
    to_port     = 9080
    protocol    = "tcp"
    cidr_blocks = ["211.244.225.166/32"]
  }

  # Node Exporter
  ingress {
    description = "Node Exporter port"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = var.monitoring_server_ips
  }

  # MySQL Exporter
  ingress {
    description = "MySQL Exporter"
    from_port   = 9104
    to_port     = 9104
    protocol    = "tcp"
    cidr_blocks = concat(["211.244.225.166/32"], var.monitoring_server_ips)
  }

  # Nginx Exporter
  ingress {
    description = "Nginx Exporter"
    from_port   = 9113
    to_port     = 9113
    protocol    = "tcp"
    cidr_blocks = var.monitoring_server_ips
  }

  # Outbound - Allow all
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${local.environment}-app-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# IAM Role for EC2 Instance
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-${local.environment}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${local.environment}-ec2-role"
  }
}

# Data source to get KMS key ARN from alias
data "aws_kms_alias" "parameter_store" {
  name = "alias/${var.project_name}-${local.environment}-parameter-store"
}

resource "aws_iam_role_policy" "parameter_store_read" {
  name = "${var.project_name}-${local.environment}-parameter-store-read"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${local.environment}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = data.aws_kms_alias.parameter_store.target_key_arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "s3_access" {
  name = "${var.project_name}-${local.environment}-s3-access"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.project_name}-${local.environment}-images/*",
          "arn:aws:s3:::${var.project_name}-${local.environment}-db-backup/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.project_name}-${local.environment}-images",
          "arn:aws:s3:::${var.project_name}-${local.environment}-db-backup"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-${local.environment}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# -----------------------------------------------------------------------------
# AMI Data Source - Ubuntu 22.04 LTS
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# -----------------------------------------------------------------------------
# EC2 Instance
# -----------------------------------------------------------------------------
resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = data.terraform_remote_state.networking.outputs.public_subnet_id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    delete_on_termination = true
    encrypted             = true

    tags = {
      Name = "${var.project_name}-${local.environment}-root-volume"
    }
  }

  user_data = base64encode(templatefile("${path.module}/scripts/user_data.sh", {
    project_name  = var.project_name
    environment   = local.environment
    frontend_port = var.frontend_port
    backend_port  = var.backend_port
    ai_port       = var.ai_port
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 required
    http_put_response_hop_limit = 1
  }

  tags = {
    Name = "${var.project_name}-${local.environment}-app"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

# -----------------------------------------------------------------------------
# Elastic IP for App Instance
# -----------------------------------------------------------------------------
resource "aws_eip" "app" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-${local.environment}-app-eip"
  }
}

resource "aws_eip_association" "app" {
  allocation_id = aws_eip.app.id
  instance_id   = aws_instance.app.id
}
