# =============================================================================
# Dev Data Layer — stateful storage
# =============================================================================

locals {
  s3_bucket_name = "doktori-v2-dev"
}

module "storage" {
  source = "../../../modules/storage"

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = var.aws_region
  create_kms_and_iam = false # dev는 KMS/IAM 불필요 — NAT 경유로 AWS API 접근, prod는 true

  s3_buckets = {
    app = {
      bucket_name        = local.s3_bucket_name
      public_read        = true
      public_read_prefix = "/images/*"
      versioning         = false
      enable_cors        = true
      encryption         = true
      bucket_key_enabled = true
      folders = [
        "backup/",
        "images/chats/",
        "images/meetings/",
        "images/profiles/",
        "images/reviews/",
      ]
    }
  }
}

# -----------------------------------------------------------------------------
# SSM — S3 파라미터 (Terraform이 버킷 이름을 알고 있으므로 직접 write)
# -----------------------------------------------------------------------------
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
