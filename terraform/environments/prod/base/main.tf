# =============================================================================
# Prod Base Layer — networking + storage
# =============================================================================

module "networking" {
  source = "../../../modules/networking"

  project_name                = var.project_name
  environment                 = var.environment
  aws_region                  = var.aws_region
  vpc_cidr                    = "10.1.0.0/16"
  availability_zone           = "ap-northeast-2a"
  secondary_availability_zone = "ap-northeast-2c"
  tertiary_availability_zone  = "ap-northeast-2b"

  subnets = {
    public        = { cidr = "10.1.0.0/22", tier = "public", az_key = "primary" }
    public_c      = { cidr = "10.1.4.0/22", tier = "public", az_key = "secondary" }
    public_b      = { cidr = "10.1.8.0/22", tier = "public", az_key = "tertiary" }
    private_app   = { cidr = "10.1.16.0/20", tier = "private-app", az_key = "primary" }
    private_app_c = { cidr = "10.1.48.0/20", tier = "private-app", az_key = "secondary" }
    private_app_b = { cidr = "10.1.64.0/20", tier = "private-app", az_key = "tertiary" }
    private_db    = { cidr = "10.1.32.0/24", tier = "private-db", az_key = "primary" }
    private_rds   = { cidr = "10.1.40.0/24", tier = "private-db", az_key = "secondary" }
  }

  nat_instances = {
    primary   = { subnet_key = "public" }
    secondary = { subnet_key = "public_c" }
  }

  internal_domain = "${var.environment}.doktori.internal"

  vpc_interface_endpoints = ["ssm", "ssmmessages", "ec2messages", "ecr.api", "ecr.dkr", "logs"]
  vpc_endpoint_subnet_key = "private_app"
}

# -----------------------------------------------------------------------------
# Storage — S3 buckets
# -----------------------------------------------------------------------------
module "storage" {
  source = "../../../modules/storage"

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = var.aws_region
  create_kms_and_iam = true

  s3_buckets = {
    app = {
      bucket_name        = "doktori-v2-prod"
      public_read        = true
      public_read_prefix = "/images/*"
      versioning         = true
      enable_cors        = true
      encryption         = true
      bucket_key_enabled = true
      folders = [
        "backup/",
        "images/meetings/",
        "images/profiles/",
        "images/reviews/",
      ]
    }
  }
}

# -----------------------------------------------------------------------------
# Account identity — ECR_REGISTRY 조립에 사용
# -----------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# SSM Parameter Store
# -----------------------------------------------------------------------------
module "ssm_parameters" {
  source = "../../../modules/ssm-parameters"

  project_name = var.project_name
  environment  = var.environment

  # prod 전용 파라미터
  # DB_URL, AI_DB_URL → prod/data 레이어에서 RDS endpoint로 Terraform write
  extra_parameters = {
    "RUNPOD_POLL_TIMEOUT_SECONDS" = { type = "SecureString" }
    "QUIZ_CACHE_TTL_SECONDS"      = { type = "String" }
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

# S3 — 버킷이 이 레이어(base)에 있으므로 여기서 write
resource "aws_ssm_parameter" "aws_s3_bucket_name" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_BUCKET_NAME"
  type  = "String"
  value = module.storage.bucket_names["app"]
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_S3_BUCKET_NAME" }
}

resource "aws_ssm_parameter" "aws_s3_db_backup" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_DB_BACKUP"
  type  = "String"
  value = module.storage.bucket_names["app"] # backup/ 폴더 공유
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_S3_DB_BACKUP" }
}

resource "aws_ssm_parameter" "aws_s3_enabled" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_ENABLED"
  type  = "String"
  value = "true"
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_S3_ENABLED" }
}

resource "aws_ssm_parameter" "aws_s3_endpoint" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_ENDPOINT"
  type  = "String"
  value = "https://s3.${var.aws_region}.amazonaws.com"
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_S3_ENDPOINT" }
}

# =============================================================================
# VPC Peering — prod ↔ mgmt (monitoring)
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

resource "aws_vpc_peering_connection" "prod_to_mgmt" {
  vpc_id      = module.networking.vpc_id
  peer_vpc_id = local.mgmt_vpc_id
  auto_accept = true

  tags = { Name = "${var.project_name}-${var.environment}-to-mgmt" }
}

# --- prod → mgmt routes ---
# public route table
resource "aws_route" "prod_public_to_mgmt" {
  route_table_id            = module.networking.public_route_table_id
  destination_cidr_block    = local.mgmt_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.prod_to_mgmt.id
}

# private route tables (all AZs)
resource "aws_route" "prod_private_to_mgmt" {
  for_each = module.networking.private_route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = local.mgmt_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.prod_to_mgmt.id
}

