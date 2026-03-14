output "parameter_names" {
  description = "Map of parameter key to full SSM path"
  value       = { for k, v in aws_ssm_parameter.this : k => v.name }
}

output "parameter_arns" {
  description = "Map of parameter key to ARN"
  value       = { for k, v in aws_ssm_parameter.this : k => v.arn }
}