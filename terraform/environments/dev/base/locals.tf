locals {
  mgmt_vpc_id   = data.terraform_remote_state.monitoring_base.outputs.vpc_id
  mgmt_vpc_cidr = data.terraform_remote_state.monitoring_base.outputs.vpc_cidr
}
