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

  subnets = {
    public        = { cidr = "10.1.0.0/22", tier = "public", az_key = "primary" }
    public_c      = { cidr = "10.1.4.0/22", tier = "public", az_key = "secondary" }
    private_app   = { cidr = "10.1.16.0/20", tier = "private-app", az_key = "primary" }
    private_app_c = { cidr = "10.1.48.0/20", tier = "private-app", az_key = "secondary" }
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
# SSM Parameter Store
# -----------------------------------------------------------------------------
module "ssm_parameters" {
  source = "../../../modules/ssm-parameters"

  project_name = var.project_name
  environment  = var.environment

  # prod 전용 파라미터 (공통 파라미터는 모듈 default로 포함)
  extra_parameters = {
    "DB_URL"                        = { type = "SecureString" }  # dev는 String
    "RUNPOD_POLL_TIMEOUT_SECONDS"   = { type = "SecureString" }  # dev는 String
    "NEXT_PUBLIC_API_BASE_URL_PROD" = { type = "String" }
    "NEXT_PUBLIC_CHAT_BASE_URL_PROD" = { type = "String" }
  }
}
