# =============================================================================
# K8s Cluster Module — Master ASG + Worker ASG + Internal NLB + Security Groups
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

# --- Master SG ---
resource "aws_security_group" "master" {
  name        = "${var.project_name}-${var.environment}-k8s-master-sg"
  description = "K8s control plane"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-k8s-master-sg" }
}

# --- Worker SG ---
resource "aws_security_group" "worker" {
  name        = "${var.project_name}-${var.environment}-k8s-worker-sg"
  description = "K8s worker nodes"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-k8s-worker-sg" }
}

# --- Master ingress rules ---

# apiserver from workers
resource "aws_vpc_security_group_ingress_rule" "master_apiserver_from_worker" {
  security_group_id            = aws_security_group.master.id
  description                  = "kube-apiserver from workers"
  from_port                    = 6443
  to_port                      = 6443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.worker.id
}

# apiserver from VPC (SSM, bastion)
resource "aws_vpc_security_group_ingress_rule" "master_apiserver_from_vpc" {
  security_group_id = aws_security_group.master.id
  description       = "kube-apiserver from VPC"
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

# apiserver from master (HA etcd communication)
resource "aws_vpc_security_group_ingress_rule" "master_apiserver_from_self" {
  security_group_id            = aws_security_group.master.id
  description                  = "kube-apiserver from master (HA)"
  from_port                    = 6443
  to_port                      = 6443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# etcd peer/client
resource "aws_vpc_security_group_ingress_rule" "master_etcd" {
  security_group_id            = aws_security_group.master.id
  description                  = "etcd peer/client"
  from_port                    = 2379
  to_port                      = 2380
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# kubelet from master
resource "aws_vpc_security_group_ingress_rule" "master_kubelet_from_self" {
  security_group_id            = aws_security_group.master.id
  description                  = "kubelet API from master"
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# kubelet from worker
resource "aws_vpc_security_group_ingress_rule" "master_kubelet_from_worker" {
  security_group_id            = aws_security_group.master.id
  description                  = "kubelet API from workers"
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.worker.id
}

# scheduler
resource "aws_vpc_security_group_ingress_rule" "master_scheduler" {
  security_group_id            = aws_security_group.master.id
  description                  = "kube-scheduler"
  from_port                    = 10259
  to_port                      = 10259
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# controller-manager
resource "aws_vpc_security_group_ingress_rule" "master_controller" {
  security_group_id            = aws_security_group.master.id
  description                  = "kube-controller-manager"
  from_port                    = 10257
  to_port                      = 10257
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# Calico VXLAN from workers
resource "aws_vpc_security_group_ingress_rule" "master_vxlan_from_worker" {
  security_group_id            = aws_security_group.master.id
  description                  = "Calico VXLAN from workers"
  from_port                    = 4789
  to_port                      = 4789
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.worker.id
}

# Calico VXLAN from self
resource "aws_vpc_security_group_ingress_rule" "master_vxlan_from_self" {
  security_group_id            = aws_security_group.master.id
  description                  = "Calico VXLAN from master"
  from_port                    = 4789
  to_port                      = 4789
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.master.id
}

# Calico Typha from workers
resource "aws_vpc_security_group_ingress_rule" "master_typha_from_worker" {
  security_group_id            = aws_security_group.master.id
  description                  = "Calico Typha from workers"
  from_port                    = 5473
  to_port                      = 5473
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.worker.id
}

# Calico Typha from self
resource "aws_vpc_security_group_ingress_rule" "master_typha_from_self" {
  security_group_id            = aws_security_group.master.id
  description                  = "Calico Typha from master"
  from_port                    = 5473
  to_port                      = 5473
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# --- Worker ingress rules ---

# kubelet from master
resource "aws_vpc_security_group_ingress_rule" "worker_kubelet" {
  security_group_id            = aws_security_group.worker.id
  description                  = "kubelet API from master"
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# NodePort from VPC
resource "aws_vpc_security_group_ingress_rule" "worker_nodeport" {
  security_group_id = aws_security_group.worker.id
  description       = "NodePort range from VPC"
  from_port         = 30000
  to_port           = 32767
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

# NodePort from NLB (external — NLB preserves client IP)
resource "aws_vpc_security_group_ingress_rule" "worker_nodeport_from_external" {
  security_group_id = aws_security_group.worker.id
  description       = "NodePort HTTP from external (NLB preserves client IP)"
  from_port         = var.worker_node_port
  to_port           = var.worker_node_port
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

# Calico VXLAN from master
resource "aws_vpc_security_group_ingress_rule" "worker_vxlan_from_master" {
  security_group_id            = aws_security_group.worker.id
  description                  = "Calico VXLAN from master"
  from_port                    = 4789
  to_port                      = 4789
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.master.id
}

# Calico VXLAN from self
resource "aws_vpc_security_group_ingress_rule" "worker_vxlan_from_self" {
  security_group_id            = aws_security_group.worker.id
  description                  = "Calico VXLAN from workers"
  from_port                    = 4789
  to_port                      = 4789
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.worker.id
}

# Calico Typha from master
resource "aws_vpc_security_group_ingress_rule" "worker_typha_from_master" {
  security_group_id            = aws_security_group.worker.id
  description                  = "Calico Typha from master"
  from_port                    = 5473
  to_port                      = 5473
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# Calico Typha from self
resource "aws_vpc_security_group_ingress_rule" "worker_typha_from_self" {
  security_group_id            = aws_security_group.worker.id
  description                  = "Calico Typha from workers"
  from_port                    = 5473
  to_port                      = 5473
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.worker.id
}

# -----------------------------------------------------------------------------
# Internal NLB (Worker NodePort)
# -----------------------------------------------------------------------------
resource "aws_lb" "nlb" {
  name               = "${var.project_name}-${var.environment}-k8s-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids

  tags = { Name = "${var.project_name}-${var.environment}-k8s-nlb" }
}

resource "aws_lb_target_group" "worker_http" {
  name        = "${var.project_name}-${var.environment}-k8s-http-tg"
  port        = var.worker_node_port
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = tostring(var.worker_node_port)
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = { Name = "${var.project_name}-${var.environment}-k8s-http-tg" }
}

resource "aws_lb_listener" "nlb_http" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.worker_http.arn
  }
}

# -----------------------------------------------------------------------------
# Launch Templates
# -----------------------------------------------------------------------------
resource "aws_launch_template" "master" {
  name_prefix   = "${var.project_name}-${var.environment}-k8s-master-"
  image_id      = local.ami_id
  instance_type = var.master_instance_type
  key_name      = var.key_name != "" ? var.key_name : null

  vpc_security_group_ids = [aws_security_group.master.id]

  iam_instance_profile {
    name = var.iam_instance_profile_name
  }

  user_data = var.user_data_master != "" ? base64encode(var.user_data_master) : null

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2 # Pod에서 IMDS 접근 필요
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = var.master_volume_size
      volume_type = "gp3"
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-${var.environment}-k8s-master"
      Role = "k8s-cp"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_launch_template" "worker" {
  name_prefix   = "${var.project_name}-${var.environment}-k8s-worker-"
  image_id      = local.ami_id
  instance_type = var.worker_instance_type
  key_name      = var.key_name != "" ? var.key_name : null

  vpc_security_group_ids = [aws_security_group.worker.id]

  iam_instance_profile {
    name = var.iam_instance_profile_name
  }

  user_data = var.user_data_worker != "" ? base64encode(var.user_data_worker) : null

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2 # Pod에서 IMDS 접근 필요
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = var.worker_volume_size
      volume_type = "gp3"
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-${var.environment}-k8s-worker"
      Role = "k8s-worker"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Auto Scaling Groups
# -----------------------------------------------------------------------------
resource "aws_autoscaling_group" "master" {
  name                = "${var.project_name}-${var.environment}-k8s-master-asg"
  desired_capacity    = var.master_desired
  min_size            = var.master_desired
  max_size            = var.master_desired
  vpc_zone_identifier = var.private_subnet_ids

  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.master.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}-k8s-master"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "k8s-cp"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_group" "worker" {
  name                = "${var.project_name}-${var.environment}-k8s-worker-asg"
  desired_capacity    = var.worker_desired
  min_size            = var.worker_min
  max_size            = var.worker_max
  vpc_zone_identifier = var.private_subnet_ids

  target_group_arns         = [aws_lb_target_group.worker_http.arn]
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}-k8s-worker"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "k8s-worker"
    propagate_at_launch = true
  }
}