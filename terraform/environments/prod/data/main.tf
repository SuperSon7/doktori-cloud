# =============================================================================
# Prod Data Layer — database (RDS)
# =============================================================================

# -----------------------------------------------------------------------------
# AWS Data Sources — replace terraform_remote_state with direct lookups
# -----------------------------------------------------------------------------
data "aws_vpc" "main" {
  tags = {
    Name = "${var.project_name}-${var.environment}-vpc"
  }
}

data "aws_subnet" "private_db" {
  vpc_id = data.aws_vpc.main.id
  tags   = { Name = "${var.project_name}-${var.environment}-private-db" }
}

data "aws_subnet" "private_rds" {
  vpc_id = data.aws_vpc.main.id
  tags   = { Name = "${var.project_name}-${var.environment}-private-rds" }
}

data "aws_route53_zone" "internal" {
  name         = "${var.environment}.doktori.internal"
  private_zone = true
  vpc_id       = data.aws_vpc.main.id
}

locals {
  net = {
    vpc_id   = data.aws_vpc.main.id
    vpc_cidr = data.aws_vpc.main.cidr_block
    subnet_ids = {
      private_db  = data.aws_subnet.private_db.id
      private_rds = data.aws_subnet.private_rds.id
    }
    internal_zone_id   = data.aws_route53_zone.internal.zone_id
    internal_zone_name = data.aws_route53_zone.internal.name
  }
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
