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
  extra_parameters = {
    "DB_URL"                            = { type = "SecureString" }
    "RUNPOD_POLL_TIMEOUT_SECONDS"       = { type = "SecureString" }
    "QUIZ_CACHE_TTL_SECONDS"            = { type = "String" }
    "REDIS_URL"                         = { type = "SecureString" }
    "SPRING_DATA_REDIS_HOST"            = { type = "String" }
    "SPRING_DATA_REDIS_PORT"            = { type = "String" }
    "NEXT_PUBLIC_API_BASE_URL_STAGING"  = { type = "String" }
    "NEXT_PUBLIC_CHAT_BASE_URL_STAGING" = { type = "String" }
  }
}
