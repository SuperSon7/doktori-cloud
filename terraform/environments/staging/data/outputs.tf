output "database" {
  description = "Database outputs"
  value = {
    db_endpoint          = module.database.db_endpoint
    db_host              = module.database.db_host
    db_port              = module.database.db_port
    db_name              = module.database.db_name
    db_username          = module.database.db_username
    db_password_ssm_path = module.database.db_password_ssm_path
    db_instance_id       = module.database.db_instance_id
    rds_sg_id            = module.database.rds_sg_id
  }
}

output "storage" {
  description = "Storage outputs for downstream layers"
  value = {
    bucket_names = module.storage.bucket_names
    bucket_arns  = module.storage.bucket_arns
  }
}
