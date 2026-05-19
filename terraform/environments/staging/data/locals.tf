locals {
  s3_bucket_name = "doktori-staging"

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
