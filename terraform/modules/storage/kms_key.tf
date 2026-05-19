# -----------------------------------------------------------------------------
# KMS Key for Parameter Store
# -----------------------------------------------------------------------------
resource "aws_kms_key" "parameter_store" {
  count = var.create_kms_and_iam ? 1 : 0

  description             = "KMS key for Parameter Store secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${var.project_name}-${var.environment}-parameter-store-key"
  }
}
