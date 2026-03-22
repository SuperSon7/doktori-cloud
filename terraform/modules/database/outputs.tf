output "db_endpoint" {
  description = "RDS endpoint (host:port)"
  value       = aws_db_instance.main.endpoint
}

output "db_host" {
  description = "RDS hostname"
  value       = aws_db_instance.main.address
}

output "db_port" {
  description = "RDS port"
  value       = aws_db_instance.main.port
}

output "db_name" {
  description = "Database name"
  value       = aws_db_instance.main.db_name
}

output "db_username" {
  description = "Master DB username"
  value       = aws_db_instance.main.username
}

output "db_password_ssm_path" {
  description = "SSM Parameter Store path for DB password"
  value       = aws_ssm_parameter.db_password.name
}

output "db_instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.main.identifier
}

output "rds_sg_id" {
  description = "RDS security group ID"
  value       = aws_security_group.rds.id
}

# RDS Proxy
output "proxy_endpoint" {
  description = "RDS Proxy endpoint (host:port)"
  value       = var.enable_rds_proxy ? aws_db_proxy.main[0].endpoint : null
}

output "proxy_host" {
  description = "RDS Proxy hostname"
  value       = var.enable_rds_proxy ? aws_db_proxy.main[0].endpoint : null
}

output "proxy_arn" {
  description = "RDS Proxy ARN"
  value       = var.enable_rds_proxy ? aws_db_proxy.main[0].arn : null
}
