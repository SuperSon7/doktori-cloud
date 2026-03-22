# =============================================================================
# Prod Data Layer — database (RDS)
# =============================================================================

data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.environment}/base/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  net = data.terraform_remote_state.base.outputs.networking
}

# -----------------------------------------------------------------------------
# Route53 — RDS internal CNAME
# -----------------------------------------------------------------------------
resource "aws_route53_record" "rds" {
  zone_id = local.net.internal_zone_id
  name    = "db.${local.net.internal_zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [module.database.db_host]
}

resource "aws_route53_record" "rds_proxy" {
  zone_id = local.net.internal_zone_id
  name    = "db-proxy.${local.net.internal_zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [module.database.proxy_host]
}

module "database" {
  source = "../../../modules/database"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  vpc_id       = local.net.vpc_id
  vpc_cidr     = local.net.vpc_cidr

  db_subnet_ids = [
    local.net.subnet_ids["private_db"],
    local.net.subnet_ids["private_rds"],
  ]

  db_engine_version        = var.db_engine_version
  db_instance_class        = var.db_instance_class
  db_allocated_storage     = var.db_allocated_storage
  db_max_allocated_storage = var.db_max_allocated_storage
  db_name                  = var.db_name
  db_username              = var.db_username
  db_backup_retention      = var.db_backup_retention
  db_availability_zone     = "ap-northeast-2a"

  db_extra_parameters = [
    { name = "slave_parallel_workers", value = "10", apply_method = "immediate" },
    { name = "slave_preserve_commit_order", value = "1", apply_method = "immediate" },
    { name = "enforce_gtid_consistency", value = "ON", apply_method = "pending-reboot" },
    { name = "gtid-mode", value = "ON", apply_method = "pending-reboot" },
  ]

  # RDS Proxy
  enable_rds_proxy = true
}
