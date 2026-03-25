# =============================================================================
# Data HA Module — Core Resources
#
# Architecture:
#   3 EC2 nodes, each in its own ASG (min=1, max=1) for self-healing.
#   Each node runs co-located:
#     - Redis (Primary or Replica) + Sentinel
#     - RabbitMQ (Quorum Queue cluster member)
#
# Self-healing flow:
#   EC2 dies → ASG detects → new EC2 created → User Data runs →
#   DNS updated → Docker services start → cluster auto-rejoin
#
# DNS strategy:
#   data-{N}.{env}.doktori.internal → each node's private IP (TTL=10s)
#   Updated by User Data on every boot via Route53 API
# =============================================================================

# -----------------------------------------------------------------------------
# AMI lookup (latest Ubuntu 22.04 ARM64)
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu_arm64" {
  count       = var.ami_id == "" ? 1 : 0
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

locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu_arm64[0].id
}

# -----------------------------------------------------------------------------
# Security Group — Redis + Sentinel + RabbitMQ + Prometheus exporters
# -----------------------------------------------------------------------------
resource "aws_security_group" "data_ha" {
  name_prefix = "${var.project_name}-${var.environment}-data-ha-"
  description = "Redis Sentinel + RabbitMQ Quorum Queue cluster"
  vpc_id      = var.vpc_id

  # --- Redis ---
  ingress {
    description = "Redis from VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "Sentinel from VPC"
    from_port   = 26379
    to_port     = 26379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # --- RabbitMQ ---
  ingress {
    description = "AMQP from VPC"
    from_port   = 5672
    to_port     = 5672
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "RabbitMQ Management from VPC"
    from_port   = 15672
    to_port     = 15672
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "Erlang distribution (inter-node)"
    from_port   = 25672
    to_port     = 25672
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "EPMD (Erlang Port Mapper)"
    from_port   = 4369
    to_port     = 4369
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # --- Prometheus exporters ---
  ingress {
    description = "Redis exporter from VPC"
    from_port   = 9121
    to_port     = 9121
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "RabbitMQ Prometheus from VPC"
    from_port   = 15692
    to_port     = 15692
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.extra_tags, {
    Name = "${var.project_name}-${var.environment}-data-ha-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Launch Template — one per node (bakes node_index into User Data)
# -----------------------------------------------------------------------------
resource "aws_launch_template" "data_ha" {
  count = var.node_count

  name_prefix   = "${var.project_name}-${var.environment}-data-${count.index + 1}-"
  image_id      = local.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name != "" ? var.key_name : null

  iam_instance_profile {
    name = aws_iam_instance_profile.data_ha.name
  }

  vpc_security_group_ids = [aws_security_group.data_ha.id]

  metadata_options {
    http_tokens                 = "required" # IMDSv2
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = var.volume_size
      volume_type = "gp3"
      encrypted   = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/userdata.sh.tpl", {
    node_index          = count.index + 1
    node_count          = var.node_count
    environment         = var.environment
    project_name        = var.project_name
    internal_domain     = var.internal_domain
    hosted_zone_id      = var.internal_zone_id
    aws_region          = var.aws_region
    redis_password_ssm  = var.redis_password_ssm
    rabbitmq_user_ssm   = var.rabbitmq_user_ssm
    rabbitmq_pass_ssm   = var.rabbitmq_pass_ssm
    rabbitmq_cookie_ssm = var.rabbitmq_cookie_ssm
    redis_maxmemory     = var.redis_maxmemory
    sentinel_down_after = var.sentinel_down_after_ms
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.extra_tags, {
      Name      = "${var.project_name}-${var.environment}-data-${count.index + 1}"
      env       = var.environment
      Part      = "data-ha"
      NodeIndex = tostring(count.index + 1)
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.extra_tags, {
      Name = "${var.project_name}-${var.environment}-data-${count.index + 1}-vol"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Auto Scaling Group — one per node (min=1, max=1 for self-healing)
#
# NOT for scaling — purely for automatic instance replacement.
# Each ASG pins to a specific subnet (AZ) for deterministic placement.
# -----------------------------------------------------------------------------
resource "aws_autoscaling_group" "data_ha" {
  count = var.node_count

  name                = "${var.project_name}-${var.environment}-data-${count.index + 1}"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [var.subnet_ids[count.index % length(var.subnet_ids)]]

  launch_template {
    id      = aws_launch_template.data_ha[count.index].id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 300 # 5min — User Data needs time to run

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0 # Single instance ASG
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}-data-${count.index + 1}"
    propagate_at_launch = true
  }

  tag {
    key                 = "Part"
    value               = "data-ha"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}