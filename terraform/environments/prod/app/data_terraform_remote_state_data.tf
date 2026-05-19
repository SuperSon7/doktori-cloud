data "terraform_remote_state" "data" {
  backend = "s3"
  config = {
    bucket = "doktori-terraform-state"
    key    = "prod/data/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
