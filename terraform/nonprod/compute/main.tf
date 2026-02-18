# -----------------------------------------------------------------------------
# Remote State References
# -----------------------------------------------------------------------------
data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "nonprod/networking/terraform.tfstate"
    region = var.aws_region
  }
}

# -----------------------------------------------------------------------------
# AMI Data Sources
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu_x86" {
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
}

data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# IAM Role for EC2 Instances (SSM + S3 + Parameter Store)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ec2_ssm" {
  name = "${var.project_name}-${var.environment}-ec2-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-ec2-ssm"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ec2_s3_access" {
  name = "${var.project_name}-${var.environment}-ec2-s3"
  role = aws_iam_role.ec2_ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::${var.project_name}-v2-${var.environment}",
          "arn:aws:s3:::${var.project_name}-v2-${var.environment}/*",
        ]
      },
    ]
  })
}

resource "aws_iam_role_policy" "ec2_parameter_store" {
  name = "${var.project_name}-${var.environment}-ec2-ssm-params"
  role = aws_iam_role.ec2_ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
        ]
        Resource = "arn:aws:kms:${var.aws_region}:*:key/*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "ec2_ecr_pull" {
  name = "${var.project_name}-${var.environment}-ec2-ecr-pull"
  role = aws_iam_role.ec2_ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:*:repository/${var.project_name}/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${var.project_name}-${var.environment}-ec2-ssm"
  role = aws_iam_role.ec2_ssm.name
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

# Dev App SG
resource "aws_security_group" "dev_app" {
  name_prefix = "${var.project_name}-${var.environment}-dev-app-"
  description = "Dev app instance security group"
  vpc_id      = data.terraform_remote_state.networking.outputs.vpc_id

  # Internal communication only (private subnet, no inbound from internet)
  ingress {
    description = "HTTP from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.networking.outputs.vpc_cidr]
  }

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.networking.outputs.vpc_cidr]
  }

  ingress {
    description = "Frontend from VPC"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.networking.outputs.vpc_cidr]
  }

  ingress {
    description = "Backend from VPC"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.networking.outputs.vpc_cidr]
  }

  ingress {
    description = "AI service from VPC"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.networking.outputs.vpc_cidr]
  }

  ingress {
    description = "MySQL from VPC"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.networking.outputs.vpc_cidr]
  }

  # Alloy push 전환으로 exporter 인바운드 포트 제거 (9100/9104/9113/9080)
  # Alloy가 내부에서 수집 → 모니터링 서버로 아웃바운드 push (egress만 필요)

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-dev-app-sg"
    Service = "app"
  }
}

# Monitoring → terraform/monitoring/ 모듈로 분리됨 (독립 state)
# 모니터링은 전체 환경(prod/dev)을 관측하므로 환경별 compute에 포함하지 않음

# -----------------------------------------------------------------------------
# EC2 Instances
# -----------------------------------------------------------------------------

# Dev App EC2 (Private App Subnet - docker-compose full stack)
resource "aws_instance" "dev_app" {
  ami                    = data.aws_ami.ubuntu_x86.id
  instance_type          = var.dev_app_instance_type
  key_name               = var.key_name
  subnet_id              = data.terraform_remote_state.networking.outputs.private_app_subnet_id
  vpc_security_group_ids = [aws_security_group.dev_app.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/scripts/user_data.sh", {
    project_name = var.project_name
    environment  = var.environment
  })

  tags = {
    Name     = "${var.project_name}-${var.environment}-dev-app"
    Service  = "app"
    Part     = "cloud"
    AutoStop = "true"
  }
}

# Monitoring EC2 → terraform/monitoring/ 모듈로 분리됨
