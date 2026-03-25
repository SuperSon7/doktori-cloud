# =============================================================================
# Data HA Module — Outputs
# =============================================================================

output "security_group_id" {
  description = "Security group ID for data HA nodes"
  value       = aws_security_group.data_ha.id
}

output "asg_names" {
  description = "List of ASG names"
  value       = [for asg in aws_autoscaling_group.data_ha : asg.name]
}

output "iam_role_arn" {
  description = "IAM role ARN for data HA nodes"
  value       = aws_iam_role.data_ha.arn
}

output "node_dns_names" {
  description = "List of DNS names for each node"
  value       = [for i in range(var.node_count) : "data-${i + 1}.${var.internal_domain}"]
}

output "sentinel_nodes" {
  description = "Comma-separated Sentinel addresses for Spring Boot config"
  value       = join(",", [for i in range(var.node_count) : "data-${i + 1}.${var.internal_domain}:26379"])
}

output "rabbitmq_addresses" {
  description = "Comma-separated RabbitMQ addresses for Spring Boot config"
  value       = join(",", [for i in range(var.node_count) : "data-${i + 1}.${var.internal_domain}:5672"])
}