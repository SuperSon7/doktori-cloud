# =============================================================================
# Storage — S3 buckets (stateful: base가 아닌 data 레이어)
# =============================================================================
module "storage" {
  source = "../../../modules/storage"

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = var.aws_region
  create_kms_and_iam = false

  s3_buckets = {
    app = {
      bucket_name        = "${var.project_name}-${var.environment}-${data.aws_caller_identity.current.account_id}"
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
