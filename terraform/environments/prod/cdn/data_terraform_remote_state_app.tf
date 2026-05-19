# -----------------------------------------------------------------------------
# Remote State — app 레이어 ALB DNS 참조
# -----------------------------------------------------------------------------
data "terraform_remote_state" "app" {
  backend = "s3"
  config = {
    bucket = "doktori-terraform-state"
    key    = "prod/app/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
