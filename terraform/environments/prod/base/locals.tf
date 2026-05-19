# =============================================================================
# Prod Base Layer — networking
# =============================================================================

locals {
  vpc_cidr     = "10.1.0.0/16"
  az_primary   = "ap-northeast-2a"
  az_secondary = "ap-northeast-2c"
  az_tertiary  = "ap-northeast-2b"
}

locals {
  mgmt_vpc_id   = data.terraform_remote_state.monitoring_base.outputs.vpc_id
  mgmt_vpc_cidr = data.terraform_remote_state.monitoring_base.outputs.vpc_cidr
}
