# =============================================================================
# Staging Data HA Layer
#
# Deploys 3-node Redis Sentinel + RabbitMQ Quorum Queue cluster.
# Each node is an ASG (min=1, max=1) for self-healing.
# Nodes are spread across 2 AZs (AZ-a, AZ-c) for fault tolerance.
#
# DNS records (auto-registered by User Data):
#   data-1.staging.doktori.internal  (AZ-a)
#   data-2.staging.doktori.internal  (AZ-c)
#   data-3.staging.doktori.internal  (AZ-a)
#
# Prerequisites:
#   1. staging/base must be applied (VPC, subnets, Route53 zone)
#   2. SSM parameters must exist:
#      /doktori/staging/REDIS_PASSWORD           (SecureString)
#      /doktori/staging/SPRING_RABBITMQ_USERNAME  (SecureString)
#      /doktori/staging/SPRING_RABBITMQ_PASSWORD  (SecureString)
#      /doktori/staging/RABBITMQ_ERLANG_COOKIE    (SecureString)
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

# -----------------------------------------------------------------------------
# Additional subnet for 3rd node (AZ-b)
# Existing subnets: private_db (AZ-a), private_rds (AZ-c)
# New subnet: private_data_b (AZ-b) for better AZ spread
# -----------------------------------------------------------------------------
resource "aws_subnet" "data_ha_b" {
  vpc_id                  = local.net.vpc_id
  cidr_block              = "10.2.36.0/24"
  availability_zone       = "ap-northeast-2b"
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-${var.environment}-private-data-b"
    Tier = "private-db"
  }
}

resource "aws_route_table_association" "data_ha_b" {
  subnet_id      = aws_subnet.data_ha_b.id
  route_table_id = local.net.private_route_table_ids["primary"]
}

# -----------------------------------------------------------------------------
# Data HA Module
# -----------------------------------------------------------------------------
module "data_ha" {
  source = "../../../modules/data-ha"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region

  vpc_id   = local.net.vpc_id
  vpc_cidr = local.net.vpc_cidr

  # 3 nodes across 3 AZs: AZ-a, AZ-c, AZ-b
  subnet_ids = [
    local.net.subnet_ids["private_db"],  # AZ-a → data-1
    local.net.subnet_ids["private_rds"], # AZ-c → data-2
    aws_subnet.data_ha_b.id,             # AZ-b → data-3
  ]

  internal_zone_id = local.net.internal_zone_id
  internal_domain  = local.net.internal_zone_name

  node_count    = 3
  instance_type = var.instance_type
  volume_size   = 20
  key_name      = var.key_name

  # SSM parameter names for credentials
  # SPRING_REDIS_PASSWORD: 앱의 application.yml과 동일한 이름 사용
  redis_password_ssm  = "/${var.project_name}/${var.environment}/SPRING_REDIS_PASSWORD"
  rabbitmq_user_ssm   = "/${var.project_name}/${var.environment}/SPRING_RABBITMQ_USERNAME"
  rabbitmq_pass_ssm   = "/${var.project_name}/${var.environment}/SPRING_RABBITMQ_PASSWORD"
  rabbitmq_cookie_ssm = "/${var.project_name}/${var.environment}/RABBITMQ_ERLANG_COOKIE"

  # Redis tuning
  redis_maxmemory        = "256mb"
  sentinel_down_after_ms = 5000

  extra_tags = {
    Layer = "data-ha"
  }
}

# -----------------------------------------------------------------------------
# Outputs — for backend application config
# -----------------------------------------------------------------------------
output "sentinel_nodes" {
  description = "Spring Boot sentinel nodes config value"
  value       = module.data_ha.sentinel_nodes
}

output "rabbitmq_addresses" {
  description = "Spring Boot RabbitMQ addresses config value"
  value       = module.data_ha.rabbitmq_addresses
}

output "node_dns_names" {
  value = module.data_ha.node_dns_names
}

output "security_group_id" {
  value = module.data_ha.security_group_id
}