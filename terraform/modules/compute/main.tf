# -----------------------------------------------------------------------------
# AMI Data Sources
# -----------------------------------------------------------------------------
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

locals {
  default_ami = {
    arm64 = var.custom_ami_id != "" ? var.custom_ami_id : data.aws_ami.ubuntu_arm64.id
    x86   = data.aws_ami.ubuntu_x86.id
  }
}

# -----------------------------------------------------------------------------
# IAM Role for EC2 Instances (SSM + S3 + Parameter Store + ECR)
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
  count = length(var.s3_bucket_arns) > 0 ? 1 : 0
  name  = "${var.project_name}-${var.environment}-ec2-s3"
  role  = aws_iam_role.ec2_ssm.id

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
        Resource = flatten([
          for arn in var.s3_bucket_arns : [arn, "${arn}/*"]
        ])
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
        Resource = flatten([
          for path in var.ssm_parameter_paths : [
            "arn:aws:ssm:${var.aws_region}:*:parameter${path}",
            "arn:aws:ssm:${var.aws_region}:*:parameter${path}/*",
          ]
        ])
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
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
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
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
# Security Groups (for_each)
# -----------------------------------------------------------------------------
resource "aws_security_group" "this" {
  for_each = var.services

  name_prefix = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}-"
  description = "${each.key} security group"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = each.value.sg_ingress
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
    }
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}-sg"
    Service = each.key
  }

  lifecycle {
    ignore_changes = [description]
  }
}

# SG cross-rules (inter-SG references — separate resource to avoid inline conflict)
resource "aws_security_group_rule" "cross" {
  for_each = {
    for rule in var.sg_cross_rules :
    "${rule.service_key}-from-${rule.source_key}-${rule.from_port}" => rule
  }

  type                     = "ingress"
  security_group_id        = aws_security_group.this[each.value.service_key].id
  source_security_group_id = aws_security_group.this[each.value.source_key].id
  from_port                = each.value.from_port
  to_port                  = each.value.to_port
  protocol                 = each.value.protocol
}

# -----------------------------------------------------------------------------
# EC2 Instances (for_each)
# -----------------------------------------------------------------------------
resource "aws_instance" "this" {
  for_each = var.services

  ami                    = each.value.ami_id != "" ? each.value.ami_id : local.default_ami[each.value.architecture]
  instance_type          = each.value.instance_type
  key_name               = var.key_name != "" ? var.key_name : null
  subnet_id              = var.subnet_ids[each.value.subnet_key]
  vpc_security_group_ids = [aws_security_group.this[each.key].id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  user_data              = each.value.user_data != "" ? each.value.user_data : null

  user_data_replace_on_change = false

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = each.value.volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(
    {
      Name    = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}"
      Service = each.key
    },
    each.value.tags,
  )

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# -----------------------------------------------------------------------------
# Elastic IPs (conditional)
# -----------------------------------------------------------------------------
resource "aws_eip" "this" {
  for_each = { for k, v in var.services : k => v if v.associate_eip }
  domain   = "vpc"

  tags = {
    Name    = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}-eip"
    Service = each.key
  }
}

resource "aws_eip_association" "this" {
  for_each = aws_eip.this

  allocation_id = each.value.id
  instance_id   = aws_instance.this[each.key].id
}
