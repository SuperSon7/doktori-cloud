output "compute" {
  description = "Compute outputs"
  value = {
    instance_ids       = module.compute.instance_ids
    private_ips        = module.compute.private_ips
    security_group_ids = module.compute.security_group_ids
    eip_public_ips     = module.compute.eip_public_ips
  }
}

output "weekly_batch" {
  description = "Weekly batch automation outputs"
  value = {
    instance_id        = module.compute.instance_ids["dev_ai_batch"]
    log_file           = "/var/log/doktori/weekly-batch.log"
    image_uri          = local.batch_image_uri
    scheduler_name     = aws_scheduler_schedule.weekly_batch_start.name
    lambda_function    = aws_lambda_function.batch_start.function_name
    tag_selector       = local.batch_tag_selector
    default_state      = aws_ec2_instance_state.batch_default_stopped.state
    ssm_parameter_path = var.batch_ssm_parameter_path
    container_command  = var.batch_container_command
  }
}
