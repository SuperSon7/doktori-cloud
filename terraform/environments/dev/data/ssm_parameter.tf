# -----------------------------------------------------------------------------
# SSM — S3 파라미터 (Terraform이 버킷 이름을 알고 있으므로 직접 write)
# -----------------------------------------------------------------------------
resource "aws_ssm_parameter" "aws_s3_bucket_name" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_BUCKET_NAME"
  type  = "String"
  value = module.storage.bucket_names["app"]
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_S3_BUCKET_NAME" }
}

resource "aws_ssm_parameter" "aws_s3_enabled" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_ENABLED"
  type  = "String"
  value = "true"
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_S3_ENABLED" }
}

resource "aws_ssm_parameter" "aws_s3_endpoint" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_ENDPOINT"
  type  = "String"
  value = "https://s3.${var.aws_region}.amazonaws.com"
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_S3_ENDPOINT" }
}
