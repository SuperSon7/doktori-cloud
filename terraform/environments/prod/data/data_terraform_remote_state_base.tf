data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = "doktori-terraform-state"
    key    = "prod/base/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
