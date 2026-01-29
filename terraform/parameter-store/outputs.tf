output "parameter_store_prefix" {
  description = "Parameter Store path prefix"
  value       = "/${var.project_name}/${local.environment}"
}

output "kms_key_arn" {
  description = "KMS key ARN for Parameter Store"
  value       = aws_kms_key.parameter_store.arn
}

output "read_policy_arn" {
  description = "IAM policy ARN for reading secrets"
  value       = aws_iam_policy.parameter_store_read.arn
}