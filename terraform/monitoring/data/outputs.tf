output "loki_bucket_name" {
  description = "Loki S3 bucket name"
  value       = aws_s3_bucket.loki.id
}

output "loki_bucket_arn" {
  description = "Loki S3 bucket ARN"
  value       = aws_s3_bucket.loki.arn
}
