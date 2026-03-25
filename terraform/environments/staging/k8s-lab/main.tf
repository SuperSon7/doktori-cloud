# =============================================================================
# K8s Lab — kubeadm 검증용 독립 레이어
# terraform destroy 한 방에 전체 정리 가능
# =============================================================================

data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.environment}/base/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  net           = data.terraform_remote_state.base.outputs.networking
  vpc_id        = local.net.vpc_id
  vpc_cidr      = local.net.vpc_cidr
  subnet_app    = local.net.subnet_ids["private_app"]
  subnet_public = local.net.subnet_ids["public"]
}

# -----------------------------------------------------------------------------
# AMI — Ubuntu 24.04 ARM64 (latest)
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

# --- Master SG ---
resource "aws_security_group" "k8s_master" {
  name        = "k8s-master-sg"
  description = "K8s control plane (kubeadm lab)"
  vpc_id      = local.vpc_id

  tags = { Name = "k8s-master-sg" }
}

# --- Worker SG ---
resource "aws_security_group" "k8s_worker" {
  name        = "k8s-worker-sg"
  description = "K8s worker nodes (kubeadm lab)"
  vpc_id      = local.vpc_id

  tags = { Name = "k8s-worker-sg" }
}

# --- Master ingress rules ---
resource "aws_vpc_security_group_ingress_rule" "master_apiserver_from_worker" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "kube-apiserver from workers"
  from_port                    = 6443
  to_port                      = 6443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

resource "aws_vpc_security_group_ingress_rule" "master_apiserver_from_vpc" {
  security_group_id = aws_security_group.k8s_master.id
  description       = "kube-apiserver from VPC (bastion/SSM)"
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
  cidr_ipv4         = local.vpc_cidr
}

resource "aws_vpc_security_group_ingress_rule" "master_etcd" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "etcd peer/client"
  from_port                    = 2379
  to_port                      = 2380
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "master_kubelet_from_self" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "kubelet API from master"
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "master_kubelet_from_worker" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "kubelet API from workers"
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

resource "aws_vpc_security_group_ingress_rule" "master_scheduler" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "kube-scheduler"
  from_port                    = 10259
  to_port                      = 10259
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "master_controller" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "kube-controller-manager"
  from_port                    = 10257
  to_port                      = 10257
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "master_vxlan_from_worker" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "Calico VXLAN from workers"
  from_port                    = 4789
  to_port                      = 4789
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

resource "aws_vpc_security_group_ingress_rule" "master_vxlan_from_self" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "Calico VXLAN from self"
  from_port                    = 4789
  to_port                      = 4789
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "master_typha_from_worker" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "Calico Typha from workers"
  from_port                    = 5473
  to_port                      = 5473
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

resource "aws_vpc_security_group_ingress_rule" "master_typha_from_self" {
  security_group_id            = aws_security_group.k8s_master.id
  description                  = "Calico Typha from master"
  from_port                    = 5473
  to_port                      = 5473
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_egress_rule" "master_all_out" {
  security_group_id = aws_security_group.k8s_master.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Worker ingress rules ---
resource "aws_vpc_security_group_ingress_rule" "worker_kubelet" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "kubelet API from master"
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "worker_nodeport" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "NodePort range from VPC"
  from_port                    = 30000
  to_port                      = 32767
  ip_protocol                  = "tcp"
  cidr_ipv4                    = local.vpc_cidr
}

resource "aws_vpc_security_group_ingress_rule" "worker_vxlan_from_master" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "Calico VXLAN from master"
  from_port                    = 4789
  to_port                      = 4789
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "worker_vxlan_from_self" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "Calico VXLAN from workers"
  from_port                    = 4789
  to_port                      = 4789
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

resource "aws_vpc_security_group_ingress_rule" "worker_typha_from_master" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "Calico Typha from master"
  from_port                    = 5473
  to_port                      = 5473
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_master.id
}

resource "aws_vpc_security_group_ingress_rule" "worker_typha_from_self" {
  security_group_id            = aws_security_group.k8s_worker.id
  description                  = "Calico Typha from workers"
  from_port                    = 5473
  to_port                      = 5473
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

resource "aws_vpc_security_group_ingress_rule" "worker_nodeport_from_external" {
  security_group_id = aws_security_group.k8s_worker.id
  description       = "NodePort HTTP from external (NLB preserves client IP)"
  from_port         = 30080
  to_port           = 30080
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "worker_all_out" {
  security_group_id = aws_security_group.k8s_worker.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Middleware SG (Redis + RabbitMQ) ---
resource "aws_security_group" "middleware" {
  name        = "k8s-lab-middleware-sg"
  description = "Redis + RabbitMQ for k8s-lab"
  vpc_id      = local.vpc_id

  tags = { Name = "k8s-lab-middleware-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "middleware_redis_from_worker" {
  security_group_id            = aws_security_group.middleware.id
  description                  = "Redis from K8s workers"
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

resource "aws_vpc_security_group_ingress_rule" "middleware_rabbitmq_from_worker" {
  security_group_id            = aws_security_group.middleware.id
  description                  = "RabbitMQ AMQP from K8s workers"
  from_port                    = 5672
  to_port                      = 5672
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k8s_worker.id
}

resource "aws_vpc_security_group_ingress_rule" "middleware_rabbitmq_mgmt_from_vpc" {
  security_group_id = aws_security_group.middleware.id
  description       = "RabbitMQ management console from VPC"
  from_port         = 15672
  to_port           = 15672
  ip_protocol       = "tcp"
  cidr_ipv4         = local.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "middleware_all_out" {
  security_group_id = aws_security_group.middleware.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# -----------------------------------------------------------------------------
# User Data — node-common.sh (containerd + kubeadm 설치)
# -----------------------------------------------------------------------------
locals {
  node_userdata = file("${path.module}/scripts/node-common.sh")
}

# -----------------------------------------------------------------------------
# EC2 Instances
# -----------------------------------------------------------------------------

resource "aws_instance" "k8s_master" {
  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = "t4g.medium"
  subnet_id              = local.subnet_app
  vpc_security_group_ids = [aws_security_group.k8s_master.id]
  iam_instance_profile   = "doktori-staging-ec2-ssm"
  user_data              = local.node_userdata

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 강제
    http_put_response_hop_limit = 2          # 컨테이너(Pod)에서 IMDS 접근 필요
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "k8s-master"
    role = "k8s-cp"
  }
}

resource "aws_instance" "k8s_worker" {
  count = 2

  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = "t4g.large"
  subnet_id              = local.subnet_app
  vpc_security_group_ids = [aws_security_group.k8s_worker.id]
  iam_instance_profile   = "doktori-staging-ec2-ssm"
  user_data              = local.node_userdata

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 강제
    http_put_response_hop_limit = 2          # 컨테이너(Pod)에서 IMDS 접근 필요
  }

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "k8s-worker-${count.index + 1}"
    role = "k8s-worker"
  }
}

# -----------------------------------------------------------------------------
# Middleware EC2 — Redis + RabbitMQ (Docker)
# -----------------------------------------------------------------------------
resource "aws_instance" "middleware" {
  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = "t4g.small"
  subnet_id              = local.subnet_app
  vpc_security_group_ids = [aws_security_group.middleware.id]
  iam_instance_profile   = "doktori-staging-ec2-ssm"

  user_data = <<-USERDATA
    #!/bin/bash
    set -e

    # Docker 설치
    apt-get update
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable docker

    # Redis + RabbitMQ 시작
    docker run -d --name redis --restart unless-stopped -p 6379:6379 redis:7-alpine
    docker run -d --name rabbitmq --restart unless-stopped \
      -p 5672:5672 -p 15672:15672 \
      -e RABBITMQ_DEFAULT_USER=doktori \
      -e RABBITMQ_DEFAULT_PASS=doktori1234 \
      rabbitmq:3-management-alpine
  USERDATA

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "k8s-lab-middleware"
    role = "middleware"
  }
}

# -----------------------------------------------------------------------------
# NLB — 외부 트래픽 → Worker NodePort(30080) 연결
# -----------------------------------------------------------------------------

resource "aws_lb" "k8s_nlb" {
  name               = "k8s-lab-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [local.subnet_public]

  tags = {
    Name = "k8s-lab-nlb"
    env  = var.environment
  }
}

# --- Target Group (TCP → NodePort 30080) ---
resource "aws_lb_target_group" "k8s_http" {
  name        = "k8s-lab-http-tg"
  port        = 30080
  protocol    = "TCP"
  vpc_id      = local.vpc_id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = "30080"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = { Name = "k8s-lab-http-tg" }
}

# --- Worker 인스턴스를 Target Group에 등록 ---
resource "aws_lb_target_group_attachment" "workers" {
  count            = length(aws_instance.k8s_worker)
  target_group_arn = aws_lb_target_group.k8s_http.arn
  target_id        = aws_instance.k8s_worker[count.index].id
  port             = 30080
}

# --- HTTP Listener (TCP 80 → TG) ---
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.k8s_nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8s_http.arn
  }
}
