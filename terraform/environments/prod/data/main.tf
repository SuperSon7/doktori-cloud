# =============================================================================
# Prod Data Layer — database (RDS)
# =============================================================================

data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = "doktori-terraform-state"
    key    = "prod/base/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

locals {
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

# -----------------------------------------------------------------------------
# SSM — DB 접속 정보 (RDS apply 후 Terraform이 직접 write)
# -----------------------------------------------------------------------------

# apply 시점에만 패스워드 읽기 — state에 저장되지 않음
ephemeral "aws_ssm_parameter" "db_password" {
  name = "/${var.project_name}/${var.environment}/DB_PASSWORD"
}

# Spring JDBC URL (패스워드 없음 — Spring은 DB_PASSWORD를 별도로 읽음)
resource "aws_ssm_parameter" "db_url" {
  name  = "/${var.project_name}/${var.environment}/DB_URL"
  type  = "String"
  value = "jdbc:mysql://${module.database.proxy_host}/${var.db_name}?serverTimezone=Asia/Seoul&useSSL=false&allowPublicKeyRetrieval=true"
  tags  = { Name = "${var.project_name}-${var.environment}-DB_URL" }
}

# Python SQLAlchemy URL (패스워드 포함 — value_wo로 state 저장 방지)
resource "aws_ssm_parameter" "ai_db_url" {
  name     = "/${var.project_name}/${var.environment}/AI_DB_URL"
  type     = "SecureString"
  value_wo = "mysql+pymysql://${module.database.db_username}:${ephemeral.aws_ssm_parameter.db_password.value}@${module.database.proxy_host}/${var.db_name}?charset=utf8mb4"
  tags     = { Name = "${var.project_name}-${var.environment}-AI_DB_URL" }
}
