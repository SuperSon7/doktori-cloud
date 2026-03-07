output "bucket_names" {
  description = "Map of bucket key to S3 bucket name"
  value       = { for k, v in aws_s3_bucket.this : k => v.id }
}

output "bucket_arns" {
  description = "Map of bucket key to S3 bucket ARN"
  value       = { for k, v in aws_s3_bucket.this : k => v.arn }
}

output "ecr_repository_urls" {
  description = "Map of repo key to ECR repository URL"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "kms_key_arn" {
  description = "Parameter Store KMS key ARN"
  value       = aws_kms_key.parameter_store.arn
}

output "kms_key_id" {
  description = "Parameter Store KMS key ID"
  value       = aws_kms_key.parameter_store.key_id
}

output "parameter_store_read_policy_arn" {
  description = "Parameter Store read IAM policy ARN"
  value       = aws_iam_policy.parameter_store_read.arn
}
