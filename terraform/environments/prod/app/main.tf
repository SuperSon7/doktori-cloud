# =============================================================================
# Prod App Layer — compute (EC2, SG, IAM, EIP)
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
  net = data.terraform_remote_state.base.outputs.networking
}

locals {
  chat_observer_user_data = templatefile("${path.module}/templates/chat_observer_user_data.sh.tftpl", {})

  # control_plane_endpoint는 Route53 CNAME (k8s.prod.doktori.internal → NLB)
  # 모듈 output 참조 시 순환참조 발생하므로 DNS 이름 직접 사용
  k8s_master_user_data = templatefile("${path.module}/templates/k8s_master_user_data.sh.tftpl", {
    region                 = var.aws_region
    project_name           = var.project_name
    environment            = var.environment
    control_plane_endpoint = "k8s.${var.environment}.doktori.internal"
    pod_cidr               = "192.168.0.0/16"
    service_cidr           = "172.16.0.0/16"
    calico_version         = "v3.29.3"
    gateway_api_version    = "v1.4.1"
    ngf_version            = "1.6.2"
  })

  k8s_worker_user_data = templatefile("${path.module}/templates/k8s_worker_user_data.sh.tftpl", {
    region       = var.aws_region
    project_name = var.project_name
    environment  = var.environment
  })
}

# -----------------------------------------------------------------------------
# Route53 — Internal DNS records
# -----------------------------------------------------------------------------
locals {
  dns_name_map = {
    nginx          = "nginx"
    front          = "front"
    api            = "api"
    chat           = "chat"
    ai             = "ai"
    rds_monitoring = "rds-exporter"
    redis          = "redis"
    rabbitmq       = "rabbitmq"
  }
}

resource "aws_route53_record" "service" {
  for_each = local.dns_name_map

  zone_id = local.net.internal_zone_id
  name    = "${each.value}.${local.net.internal_zone_name}"
  type    = "A"
  ttl     = 300
  records = [module.compute.private_ips[each.key]]
}

module "compute" {
  source = "../../../modules/compute"

  project_name           = var.project_name
  environment            = var.environment
  aws_region             = var.aws_region
  vpc_id                 = local.net.vpc_id
  enable_batch_self_stop = true
  vpc_cidr               = local.net.vpc_cidr
  subnet_ids             = local.net.subnet_ids
  key_name               = var.key_name

  s3_bucket_arns = [
    "arn:aws:s3:::${var.project_name}-v2-${var.environment}",
  ]

  ssm_parameter_paths = [
    "/${var.project_name}/${var.environment}",
  ]

  services = {
    nginx = {
      instance_type = "t4g.micro"
      architecture  = "arm64"
      subnet_key    = "public"
      associate_eip = true
      tags          = { Part = "cloud" }
      sg_ingress = [
        { description = "HTTP from anywhere", from_port = 80, to_port = 80, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "HTTPS from anywhere", from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
      ]
    }
    front = {
      instance_type = "t4g.small"
      architecture  = "arm64"
      subnet_key    = "private_app"
      tags          = { Part = "fe" }
      sg_ingress    = []
    }
    api = {
      instance_type = "t4g.small"
      architecture  = "arm64"
      subnet_key    = "private_app"
      tags          = { Part = "be" }
      sg_ingress    = []
    }
    chat = {
      instance_type = "t4g.medium"
      architecture  = "arm64"
      subnet_key    = "private_app"
      tags          = { Part = "be" }
      sg_ingress    = []
    }
    ai = {
      instance_type = "t4g.medium"
      architecture  = "arm64"
      subnet_key    = "private_app"
      tags          = { Part = "ai" }
      sg_ingress    = []
    }
    rds_monitoring = {
      instance_type = "t3.micro"
      architecture  = "x86"
      subnet_key    = "public"
      tags          = { Part = "monitoring" }
      sg_ingress = [
        { description = "MySQL exporter from VPC", from_port = 9104, to_port = 9104, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
      ]
    }
    redis = {
      instance_type = "t4g.micro"
      architecture  = "arm64"
      subnet_key    = "private_app"
      tags          = { Part = "data" }
      sg_ingress = [
        { description = "Redis from VPC", from_port = 6379, to_port = 6379, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
      ]
    }
    rabbitmq = {
      instance_type = "t4g.micro"
      architecture  = "arm64"
      subnet_key    = "private_app"
      tags          = { Part = "data" }
      sg_ingress = [
        { description = "RabbitMQ AMQP from VPC", from_port = 5672, to_port = 5672, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "RabbitMQ mgmt from VPC", from_port = 15672, to_port = 15672, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
      ]
    }
    chat_observer = {
      instance_type              = var.chat_observer_instance_type
      architecture               = "x86"
      subnet_key                 = "public"
      associate_eip              = true
      existing_eip_allocation_id = ""
      user_data                  = local.chat_observer_user_data
      tags                       = { Part = "loadtest-observer" }
      sg_ingress = length(var.chat_observer_allowed_cidrs) > 0 ? [
        { description = "HTTPS from allowed observer CIDRs", from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = var.chat_observer_allowed_cidrs },
      ] : []
    }
  }

  sg_cross_rules = [
    { service_key = "front", source_key = "nginx", from_port = 3000, to_port = 3001, protocol = "tcp" },
    { service_key = "api", source_key = "nginx", from_port = 8080, to_port = 8082, protocol = "tcp" },
    { service_key = "chat", source_key = "nginx", from_port = 8081, to_port = 8083, protocol = "tcp" },
    { service_key = "ai", source_key = "nginx", from_port = 8000, to_port = 8000, protocol = "tcp" },
  ]
}

# =============================================================================
# Frontend — ALB + ASG (Multi-AZ)
# =============================================================================
module "frontend" {
  source = "../../../modules/frontend"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = local.net.vpc_id
  vpc_cidr     = local.net.vpc_cidr
  key_name     = var.key_name

  public_subnet_ids = [
    local.net.subnet_ids["public"],
    local.net.subnet_ids["public_c"],
  ]
  private_subnet_ids = [
    local.net.subnet_ids["private_app"],
    local.net.subnet_ids["private_app_c"],
  ]

  ami_id                    = "ami-062480ce1fc9b3271"
  instance_type             = "t4g.small"
  iam_instance_profile_name = module.compute.iam_instance_profile_name
  desired_capacity          = 2
  min_size                  = 2
  max_size                  = 4
}

# =============================================================================
# K8s Cluster — Master ASG + Worker ASG + Internal NLB (Multi-AZ)
# =============================================================================
module "k8s_cluster" {
  source = "../../../modules/k8s-cluster"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = local.net.vpc_id
  vpc_cidr     = local.net.vpc_cidr
  key_name     = var.key_name

  public_subnet_ids = [
    local.net.subnet_ids["public"],
    local.net.subnet_ids["public_c"],
  ]
  private_subnet_ids = [
    local.net.subnet_ids["private_app"],
    local.net.subnet_ids["private_app_c"],
    local.net.subnet_ids["private_app_b"],
  ]

  ami_id                    = "ami-0ef978e3253fc81b2"
  iam_instance_profile_name = module.compute.iam_instance_profile_name

  master_instance_type = "t4g.medium"
  master_desired       = 3
  user_data_master     = local.k8s_master_user_data

  worker_instance_type = "t4g.large"
  worker_desired       = 4
  worker_min           = 2
  worker_max           = 6
  user_data_worker     = local.k8s_worker_user_data
}

# =============================================================================
# DNS — ALB / NLB alias records
# =============================================================================

# Frontend ALB → front-alb.prod.doktori.internal
resource "aws_route53_record" "frontend_alb" {
  zone_id = local.net.internal_zone_id
  name    = "front-alb.${local.net.internal_zone_name}"
  type    = "A"

  alias {
    name                   = module.frontend.alb_dns_name
    zone_id                = module.frontend.alb_zone_id
    evaluate_target_health = true
  }
}

# K8s Internal NLB → k8s.prod.doktori.internal
resource "aws_route53_record" "k8s_nlb" {
  zone_id = local.net.internal_zone_id
  name    = "k8s.${local.net.internal_zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [module.k8s_cluster.nlb_dns_name]
}

# =============================================================================
# Unified ALB Routing — Frontend ALB에 path-based 규칙 추가
#   nginx/prod/sites-available/default 라우팅 패턴 기반:
#   /api/*   → K8s Worker NodePort (30080) → NGF → api/chat 분기
#   /ws/*    → K8s Worker NodePort (30080) → NGF (WebSocket)
#   /ai/*    → AI EC2 (port 8000)
#   /* (default) → Frontend ASG (port 3000)
# =============================================================================

# --- K8s Backend Target Group (Worker NodePort 30080) ---
resource "aws_lb_target_group" "k8s_backend" {
  name     = "${var.project_name}-${var.environment}-k8s-be-tg"
  port     = 30080
  protocol = "HTTP"
  vpc_id   = local.net.vpc_id

  health_check {
    path                = "/"
    port                = "30080"
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-404"
  }

  tags = { Name = "${var.project_name}-${var.environment}-k8s-be-tg" }
}

resource "aws_autoscaling_attachment" "worker_alb" {
  autoscaling_group_name = module.k8s_cluster.worker_asg_name
  lb_target_group_arn    = aws_lb_target_group.k8s_backend.arn
}

# --- AI Target Group (port 8000) ---
resource "aws_lb_target_group" "ai" {
  name     = "${var.project_name}-${var.environment}-ai-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = local.net.vpc_id

  health_check {
    path                = "/ai/health"
    port                = "8000"
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = { Name = "${var.project_name}-${var.environment}-ai-tg" }
}

resource "aws_lb_target_group_attachment" "ai" {
  target_group_arn = aws_lb_target_group.ai.arn
  target_id        = module.compute.instance_ids["ai"]
  port             = 8000
}

# --- ALB Listener Rules (path-based routing) ---
# /api/* → K8s (NGF가 /api/chat/, /api/chat-rooms/, /api/ 분기)
resource "aws_lb_listener_rule" "api" {
  listener_arn = module.frontend.http_listener_arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8s_backend.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}

# /ws/* → K8s (WebSocket — /ws/chat 등)
resource "aws_lb_listener_rule" "ws" {
  listener_arn = module.frontend.http_listener_arn
  priority     = 110

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8s_backend.arn
  }

  condition {
    path_pattern {
      values = ["/ws/*"]
    }
  }
}

# /ai/* → AI EC2
resource "aws_lb_listener_rule" "ai" {
  listener_arn = module.frontend.http_listener_arn
  priority     = 120

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ai.arn
  }

  condition {
    path_pattern {
      values = ["/ai/*"]
    }
  }
}

# /* (default) → Frontend ASG (listener default action, 변경 없음)

# --- SG: Worker NodePort from ALB ---
resource "aws_vpc_security_group_ingress_rule" "worker_from_alb" {
  security_group_id            = module.k8s_cluster.worker_sg_id
  description                  = "NodePort HTTP from public ALB"
  from_port                    = 30080
  to_port                      = 30080
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.frontend.alb_sg_id
}

# --- SG: AI from ALB ---
resource "aws_vpc_security_group_ingress_rule" "ai_from_alb" {
  security_group_id            = module.compute.security_group_ids["ai"]
  description                  = "AI API from public ALB"
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.frontend.alb_sg_id
}
