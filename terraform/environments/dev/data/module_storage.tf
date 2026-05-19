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
        "images/chats/",
        "images/meetings/",
        "images/profiles/",
        "images/reviews/",
      ]
    }
  }
}
