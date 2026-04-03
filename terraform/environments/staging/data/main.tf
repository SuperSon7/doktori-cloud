# =============================================================================
# Staging Data Layer — database (disposable RDS) + S3
# =============================================================================

data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = "doktori-terraform-state"
    key    = "staging/base/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

locals {
  s3_bucket_name = "doktori-v2-staging"

  net = {
    vpc_id   = data.terraform_remote_state.base.outputs.networking.vpc_id
    vpc_cidr = data.terraform_remote_state.base.outputs.networking.vpc_cidr
    subnet_ids = {
      private_db  = data.terraform_remote_state.base.outputs.networking.subnet_ids["private_db"]
      private_rds = data.terraform_remote_state.base.outputs.networking.subnet_ids["private_rds"]
    }
    internal_zone_id   = data.terraform_remote_state.base.outputs.networking.internal_zone_id
    internal_zone_name = data.terraform_remote_state.base.outputs.networking.internal_zone_name
  }
}

# -----------------------------------------------------------------------------
# S3 — staging 버킷 (테스트용, versioning/CORS 포함)
# -----------------------------------------------------------------------------
module "storage" {
  source = "../../../modules/storage"

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = var.aws_region
  create_kms_and_iam = false # staging S3는 KMS 불필요

  s3_buckets = {
    app = {
      bucket_name        = local.s3_bucket_name
      public_read        = true
      public_read_prefix = "/images/*"
      versioning         = false
      enable_cors        = true
      encryption         = true
      bucket_key_enabled = false
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
# Route53 — RDS internal CNAME
# -----------------------------------------------------------------------------
resource "aws_route53_record" "rds" {
  zone_id = local.net.internal_zone_id
  name    = "db.${local.net.internal_zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [module.database.db_host]
}

module "database" {
  source = "../../../modules/database"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  vpc_id       = local.net.vpc_id
  vpc_cidr     = local.net.vpc_cidr

  db_subnet_ids = [
    local.net.subnet_ids["private_db"],
    local.net.subnet_ids["private_rds"],
  ]

  db_engine_version        = var.db_engine_version
  db_instance_class        = var.db_instance_class
  db_allocated_storage     = var.db_allocated_storage
  db_max_allocated_storage = var.db_max_allocated_storage
  db_name                  = var.db_name
  db_username              = var.db_username
  db_backup_retention      = var.db_backup_retention
  db_availability_zone     = "ap-northeast-2a"

  # Staging: disposable — no deletion protection, no final snapshot
  deletion_protection = false
  skip_final_snapshot = true
}

# -----------------------------------------------------------------------------
# SSM — Terraform이 직접 쓰는 값
# -----------------------------------------------------------------------------

# apply 시점에만 패스워드 읽기 — state에 저장되지 않음
ephemeral "aws_ssm_parameter" "db_password" {
  name = "/${var.project_name}/${var.environment}/DB_PASSWORD"
}

# Spring JDBC URL (패스워드 없음, staging은 proxy 없이 직접 RDS)
resource "aws_ssm_parameter" "db_url" {
  name  = "/${var.project_name}/${var.environment}/DB_URL"
  type  = "String"
  value = "jdbc:mysql://${module.database.db_host}:${module.database.db_port}/${var.db_name}?serverTimezone=Asia/Seoul&useSSL=false&allowPublicKeyRetrieval=true"
  tags  = { Name = "${var.project_name}-${var.environment}-DB_URL" }
}

# Python SQLAlchemy URL (패스워드 포함 — value_wo로 state 저장 방지)
resource "aws_ssm_parameter" "ai_db_url" {
  name     = "/${var.project_name}/${var.environment}/AI_DB_URL"
  type     = "SecureString"
  value_wo = "mysql+pymysql://${module.database.db_username}:${ephemeral.aws_ssm_parameter.db_password.value}@${module.database.db_host}:${module.database.db_port}/${var.db_name}?charset=utf8mb4"
  tags     = { Name = "${var.project_name}-${var.environment}-AI_DB_URL" }
}

resource "aws_ssm_parameter" "aws_s3_bucket_name" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_BUCKET_NAME"
  type  = "String"
  value = module.storage.bucket_names["app"]
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_S3_BUCKET_NAME" }
}

resource "aws_ssm_parameter" "aws_s3_db_backup" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_DB_BACKUP"
  type  = "String"
  value = module.storage.bucket_names["app"]
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
