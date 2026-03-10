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
    public      = { cidr = "10.1.0.0/22", tier = "public", az_key = "primary" }
    private_app = { cidr = "10.1.16.0/20", tier = "private-app", az_key = "primary" }
    private_db  = { cidr = "10.1.32.0/24", tier = "private-db", az_key = "primary" }
    private_rds = { cidr = "10.1.40.0/24", tier = "private-db", az_key = "secondary" }
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
  create_kms_and_iam = false # 기존 수동 생성 KMS/IAM 유지 — Phase 1에서 import 예정

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
