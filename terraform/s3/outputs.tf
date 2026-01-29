output "bucket_name" {
  description = "S3 bucket name"
  value       = aws_s3_bucket.images.id
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.images.arn
}

output "bucket_endpoint" {
  description = "S3 bucket endpoint URL"
  value       = "https://${aws_s3_bucket.images.bucket_regional_domain_name}"
}

output "bucket_domain" {
  description = "S3 bucket domain"
  value       = aws_s3_bucket.images.bucket_regional_domain_name
}

# Developer credentials (for local development)
output "developer_access_key_id" {
  description = "Developer IAM user access key ID"
  value       = aws_iam_access_key.s3_developer.id
  sensitive   = true
}

output "developer_secret_access_key" {
  description = "Developer IAM user secret access key"
  value       = aws_iam_access_key.s3_developer.secret
  sensitive   = true
}