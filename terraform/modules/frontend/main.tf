# =============================================================================
# Frontend Module — ALB + ASG + Security Groups
# =============================================================================

# -----------------------------------------------------------------------------
# AMI (fallback: Ubuntu 22.04 ARM64)
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu_arm64" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"]

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
# Security Groups
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-frontend-alb-sg"
  description = "Public ALB for frontend"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-frontend-alb-sg" }
}

resource "aws_security_group" "instance" {
  name        = "${var.project_name}-${var.environment}-frontend-sg"
  description = "Frontend ASG instances"
  vpc_id      = var.vpc_id

  ingress {
    description     = "App port from ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-frontend-sg" }
}

# -----------------------------------------------------------------------------
# ALB
# -----------------------------------------------------------------------------
resource "aws_lb" "this" {
  name               = "${var.project_name}-${var.environment}-fe-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  # WebSocket/SSE 연결 유지를 위해 3600초(1시간)로 설정
  # ALB 기본값은 60초 → WS idle 시 조기 끊김 발생
  idle_timeout = var.idle_timeout

  tags = { Name = "${var.project_name}-${var.environment}-fe-alb" }
}

resource "aws_lb_target_group" "this" {
  name                 = "${var.project_name}-${var.environment}-fe-tg"
  port                 = var.app_port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  deregistration_delay = 300

  health_check {
    path                = var.health_check_path
    port                = tostring(var.app_port)
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }

  tags = { Name = "${var.project_name}-${var.environment}-fe-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# -----------------------------------------------------------------------------
# Launch Template + ASG
# -----------------------------------------------------------------------------
resource "aws_launch_template" "this" {
  name_prefix   = "${var.project_name}-${var.environment}-frontend-"
  image_id      = local.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name != "" ? var.key_name : null

  vpc_security_group_ids = concat(
    [aws_security_group.instance.id],
    var.extra_sg_ids,
  )

  iam_instance_profile {
    name = var.iam_instance_profile_name
  }

  user_data = var.user_data != "" ? base64encode(var.user_data) : null

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = var.volume_size
      volume_type = "gp3"
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-${var.environment}-frontend"
      Part = "fe"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name                = "${var.project_name}-${var.environment}-frontend-asg"
  desired_capacity    = var.desired_capacity
  min_size            = var.min_size
  max_size            = var.max_size
  vpc_zone_identifier = var.private_subnet_ids

  target_group_arns         = [aws_lb_target_group.this.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}-frontend"
    propagate_at_launch = true
  }
}
