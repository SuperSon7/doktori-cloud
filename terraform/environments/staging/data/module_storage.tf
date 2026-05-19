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
