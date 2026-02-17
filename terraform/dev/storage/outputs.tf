output "images_bucket_name" {
  description = "Images S3 bucket name"
  value       = aws_s3_bucket.images.id
}

output "images_bucket_arn" {
  description = "Images S3 bucket ARN"
  value       = aws_s3_bucket.images.arn
}

output "db_backup_bucket_name" {
  description = "DB backup S3 bucket name"
  value       = aws_s3_bucket.db_backup.id
}

output "ecr_backend_api_url" {
  description = "ECR backend-api repository URL"
  value       = aws_ecr_repository.backend_api.repository_url
}

output "ecr_backend_chat_url" {
  description = "ECR backend-chat repository URL"
  value       = aws_ecr_repository.backend_chat.repository_url
}

output "ecr_frontend_url" {
  description = "ECR frontend repository URL"
  value       = aws_ecr_repository.frontend.repository_url
}

output "ecr_ai_url" {
  description = "ECR AI repository URL"
  value       = aws_ecr_repository.ai.repository_url
}

output "kms_key_arn" {
  description = "Parameter Store KMS key ARN"
  value       = aws_kms_key.parameter_store.arn
}

output "parameter_store_read_policy_arn" {
  description = "Parameter Store read IAM policy ARN"
  value       = aws_iam_policy.parameter_store_read.arn
}
