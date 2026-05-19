output "database" {
  description = "Database outputs"
  value = {
    db_endpoint          = module.database.db_endpoint
    db_host              = module.database.db_host
    db_port              = module.database.db_port
    db_name              = module.database.db_name
    db_username          = module.database.db_username
    db_password_ssm_path = module.database.db_password_ssm_path
    db_password_ssm_arn  = module.database.db_password_ssm_arn
    db_instance_id       = module.database.db_instance_id
    rds_sg_id            = module.database.rds_sg_id
    proxy_endpoint       = module.database.proxy_endpoint
    proxy_host           = module.database.proxy_host
  }
}

output "storage" {
  description = "Storage outputs for downstream layers"
  value = {
    bucket_names = module.storage.bucket_names
    bucket_arns  = module.storage.bucket_arns
  }
}

output "codedeploy_revisions" {
  description = "CodeDeploy revision bucket for app layer reference"
  value = {
    bucket = aws_s3_bucket.frontend_codedeploy_revisions.bucket
    arn    = aws_s3_bucket.frontend_codedeploy_revisions.arn
  }
}

output "data_services" {
  description = "Self-managed data service outputs"
  value = {
    instance_ids = module.data_compute.instance_ids
    private_ips  = module.data_compute.private_ips
    dns = {
      redis             = aws_route53_record.redis.fqdn
      redis_sentinel    = var.enable_data_ha ? aws_route53_record.redis_sentinel[0].fqdn : null
      rabbitmq          = aws_route53_record.rabbitmq.fqdn
      mongodb           = aws_route53_record.data_service["mongodb"].fqdn
      redis_nodes       = { for key in local.redis_service_keys : key => aws_route53_record.data_service[key].fqdn }
      rabbitmq_nodes    = { for key in local.rabbitmq_service_keys : key => aws_route53_record.data_service[key].fqdn }
      redis_master_name = local.redis_sentinel_master
      ha_enabled        = var.enable_data_ha
    }
  }
}
