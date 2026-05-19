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
