# =============================================================================
# Staging Base Layer — networking (no VPC endpoints for cost savings)
# =============================================================================

module "networking" {
  source = "../../../modules/networking"

  project_name                = var.project_name
  environment                 = var.environment
  aws_region                  = var.aws_region
  vpc_cidr                    = "10.2.0.0/16"
  availability_zone           = "ap-northeast-2a"
  secondary_availability_zone = "ap-northeast-2c"
  tertiary_availability_zone  = "ap-northeast-2b"

  subnets = {
    public      = { cidr = "10.2.0.0/22", tier = "public", az_key = "primary" }
    private_app = { cidr = "10.2.16.0/20", tier = "private-app", az_key = "primary" }
    private_db  = { cidr = "10.2.32.0/24", tier = "private-db", az_key = "primary" }
    private_rds = { cidr = "10.2.40.0/24", tier = "private-db", az_key = "secondary" }
    private_k8s_a = { cidr = "10.2.48.0/24", tier = "private-app", az_key = "primary" }
    private_k8s_b = { cidr = "10.2.49.0/24", tier = "private-app", az_key = "tertiary" }
  }

  internal_domain = "${var.environment}.doktori.internal"

  # No VPC endpoints — routes through NAT (saves ~$60/month)
  vpc_interface_endpoints = []
}

# -----------------------------------------------------------------------------
# Account identity — ECR_REGISTRY 조립에 사용
# -----------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Storage — KMS for Parameter Store
# -----------------------------------------------------------------------------
module "storage" {
  source = "../../../modules/storage"

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = var.aws_region
  create_kms_and_iam = true
}

# -----------------------------------------------------------------------------
# SSM Parameter Store
# -----------------------------------------------------------------------------
module "ssm_parameters" {
  source = "../../../modules/ssm-parameters"

  project_name = var.project_name
  environment  = var.environment

  # 공통 파라미터는 모듈 default 사용 (dev/prod와 동일)

  # staging 전용 파라미터
  # DB_URL, AI_DB_URL → staging/data 레이어에서 RDS endpoint로 Terraform write
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
