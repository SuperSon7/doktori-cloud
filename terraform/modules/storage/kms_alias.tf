resource "aws_kms_alias" "parameter_store" {
  count = var.create_kms_and_iam ? 1 : 0

  name          = "alias/${var.project_name}-${var.environment}-parameter-store"
  target_key_id = aws_kms_key.parameter_store[0].key_id
}
