module "database" {
  source = "../../../modules/database"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  vpc_id       = local.net.vpc_id
  vpc_cidr     = local.net.vpc_cidr

  db_subnet_ids = [
    local.net.subnet_ids["private_db_a"],
    local.net.subnet_ids["private_db_c"],
  ]

  db_engine_version         = var.db_engine_version
  db_parameter_group_family = var.db_parameter_group_family
  db_instance_class         = var.db_instance_class
  db_allocated_storage      = var.db_allocated_storage
  db_max_allocated_storage  = var.db_max_allocated_storage
  db_name                   = var.db_name
  db_username               = var.db_username
  db_backup_retention       = var.db_backup_retention
  db_availability_zone      = "ap-northeast-2a"

  db_extra_parameters = [
    { name = "replica_parallel_workers", value = "10", apply_method = "immediate" },
    { name = "replica_preserve_commit_order", value = "1", apply_method = "immediate" },
    { name = "enforce_gtid_consistency", value = "ON", apply_method = "pending-reboot" },
    { name = "gtid-mode", value = "ON", apply_method = "pending-reboot" },
  ]

  # RDS Proxy
  enable_rds_proxy = true
}
