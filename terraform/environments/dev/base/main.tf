# =============================================================================
# Dev Base Layer — networking + storage
# =============================================================================

# Ubuntu 24.04 ARM64 for NAT instance (dev uses Ubuntu, not Amazon Linux)
data "aws_ami" "nat_ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

module "networking" {
  source = "../../../modules/networking"

  project_name      = var.project_name
  environment       = var.environment
  aws_region        = var.aws_region
  vpc_cidr          = "10.0.0.0/16"
  availability_zone = "ap-northeast-2a"

  subnets = {
    public      = { cidr = "10.0.0.0/22", tier = "public", az_key = "primary" }
    private_app = { cidr = "10.0.16.0/20", tier = "private-app", az_key = "primary" }
    private_db  = { cidr = "10.0.32.0/24", tier = "private-db", az_key = "primary" }
  }

  nat_ami_id        = data.aws_ami.nat_ubuntu.id
  nat_instance_type = "t4g.micro"
  nat_volume_size   = 10
  nat_key_name      = var.nat_key_name
  nat_user_data     = <<-USERDATA
    #!/bin/bash
    set -e

    # IP forwarding 활성화
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p

    # iptables MASQUERADE (아웃바운드 인터페이스 자동 감지)
    IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
    iptables -t nat -A POSTROUTING -o "$IFACE" -s 10.0.0.0/16 -j MASQUERADE

    # iptables 영속화
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
    netfilter-persistent save
  USERDATA

  nat_extra_tags = {
    Name     = "doktori-dev-nat-vpn"
    Service  = "nat-vpn"
    AutoStop = "false"
    Owner    = "cloud"
  }

  internal_domain = "dev.doktori.internal"

  # dev는 Interface Endpoint 미사용 (비용 절감 — NAT 경유로 AWS API 접근)
  vpc_interface_endpoints = []

  # WireGuard VPN — dev NAT 인스턴스에서 VPN 서버 운용
  nat_extra_ingress = [
    { description = "WireGuard VPN", from_port = 51820, to_port = 51820, protocol = "udp", cidr_blocks = ["0.0.0.0/0"] },
  ]
}

# -----------------------------------------------------------------------------
# Account identity — ECR_REGISTRY 조립에 사용
# -----------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# SSM Parameter Store
# -----------------------------------------------------------------------------
resource "random_password" "qdrant_api_key" {
  length           = 32
  special          = false
  override_special = ""
}

# =============================================================================
# VPC Peering — dev ↔ mgmt (monitoring)
# =============================================================================
data "terraform_remote_state" "monitoring_base" {
  backend = "s3"
  config = {
    bucket = "doktori-terraform-state"
    key    = "monitoring/base/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

locals {
  mgmt_vpc_id   = data.terraform_remote_state.monitoring_base.outputs.vpc_id
  mgmt_vpc_cidr = data.terraform_remote_state.monitoring_base.outputs.vpc_cidr
}

resource "aws_vpc_peering_connection" "dev_to_mgmt" {
  vpc_id      = module.networking.vpc_id
  peer_vpc_id = local.mgmt_vpc_id
  auto_accept = true

  tags = { Name = "${var.project_name}-${var.environment}-to-mgmt" }
}

# --- dev → mgmt routes ---
# public route table
resource "aws_route" "dev_public_to_mgmt" {
  route_table_id            = module.networking.public_route_table_id
  destination_cidr_block    = local.mgmt_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.dev_to_mgmt.id
}

# private route tables (all AZs)
resource "aws_route" "dev_private_to_mgmt" {
  for_each = module.networking.private_route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = local.mgmt_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.dev_to_mgmt.id
}
# -----------------------------------------------------------------------------
# SSM Parameter Store
# -----------------------------------------------------------------------------
module "ssm_parameters" {
  source = "../../../modules/ssm-parameters"

  project_name = var.project_name
  environment  = var.environment

  # dev 전용 파라미터 (공통 파라미터는 모듈 default로 포함)
  extra_parameters = {
    # Docker Compose DB — prod/staging은 Terraform이 RDS endpoint로 write
    "DB_URL"    = { type = "String" }
    "AI_DB_URL" = { type = "SecureString" }

    "RUNPOD_POLL_TIMEOUT_SECONDS" = { type = "String" }
    "QUIZ_CACHE_TTL_SECONDS"      = { type = "String" }
    "MONGO_URI"                   = { type = "SecureString" }
  }
}

# -----------------------------------------------------------------------------
# SSM — Terraform이 직접 쓰는 값 (CHANGE_ME 불필요, ignore_changes 없음)
# -----------------------------------------------------------------------------
resource "aws_ssm_parameter" "aws_region" {
  name  = "/${var.project_name}/${var.environment}/AWS_REGION"
  type  = "String"
  value = var.aws_region
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_REGION" }
}

resource "aws_ssm_parameter" "ecr_registry" {
  name  = "/${var.project_name}/${var.environment}/ECR_REGISTRY"
  type  = "String"
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  tags  = { Name = "${var.project_name}-${var.environment}-ECR_REGISTRY" }
}

resource "aws_ssm_parameter" "spring_redis_port" {
  name  = "/${var.project_name}/${var.environment}/SPRING_REDIS_PORT"
  type  = "String"
  value = "6379"
  tags  = { Name = "${var.project_name}-${var.environment}-SPRING_REDIS_PORT" }
}

resource "aws_ssm_parameter" "spring_rabbitmq_port" {
  name  = "/${var.project_name}/${var.environment}/SPRING_RABBITMQ_PORT"
  type  = "String"
  value = "5672"
  tags  = { Name = "${var.project_name}-${var.environment}-SPRING_RABBITMQ_PORT" }
}

resource "aws_ssm_parameter" "qdrant_url" {
  name  = "/${var.project_name}/${var.environment}/QDRANT_URL"
  type  = "String"
  value = "http://ai-qdrant.${module.networking.internal_zone_name}:6333"

  tags = {
    Name = "${var.project_name}-${var.environment}-QDRANT_URL"
  }

  lifecycle {
    # CLI로 실제 값을 주입하므로 Terraform이 덮어쓰지 않도록 ignore
    ignore_changes = [value, description]
  }
}

resource "aws_ssm_parameter" "qdrant_api_key" {
  name  = "/${var.project_name}/${var.environment}/QDRANT_API_KEY"
  type  = "SecureString"
  value = random_password.qdrant_api_key.result

  tags = {
    Name = "${var.project_name}-${var.environment}-QDRANT_API_KEY"
  }

  lifecycle {
    # CLI로 실제 값을 주입하므로 Terraform이 덮어쓰지 않도록 ignore
    ignore_changes = [value, description]
  }
}

resource "aws_ssm_parameter" "qdrant_location" {
  name  = "/${var.project_name}/${var.environment}/QDRANT_LOCATION"
  type  = "String"
  value = ":memory:"

  tags = {
    Name = "${var.project_name}-${var.environment}-QDRANT_LOCATION"
  }

  lifecycle {
    # CLI로 실제 값을 주입하므로 Terraform이 덮어쓰지 않도록 ignore
    ignore_changes = [value, description]
  }
}

resource "aws_ssm_parameter" "qdrant_collection_discussion" {
  name  = "/${var.project_name}/${var.environment}/QDRANT_COLLECTION_DISCUSSION"
  type  = "String"
  value = "discussion_topics_dev"

  tags = {
    Name = "${var.project_name}-${var.environment}-QDRANT_COLLECTION_DISCUSSION"
  }

  lifecycle {
    # CLI로 실제 값을 주입하므로 Terraform이 덮어쓰지 않도록 ignore
    ignore_changes = [value, description]
  }
}

resource "aws_ssm_parameter" "qdrant_collection_reco" {
  name  = "/${var.project_name}/${var.environment}/QDRANT_COLLECTION_RECO"
  type  = "String"
  value = "reco_meetings_dev"

  tags = {
    Name = "${var.project_name}-${var.environment}-QDRANT_COLLECTION_RECO"
  }

  lifecycle {
    # CLI로 실제 값을 주입하므로 Terraform이 덮어쓰지 않도록 ignore
    ignore_changes = [value, description]
  }
}
