data "terraform_remote_state" "monitoring_base" {
  backend = "s3"
  config = {
    bucket = "doktori-terraform-state"
    key    = "monitoring/base/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
