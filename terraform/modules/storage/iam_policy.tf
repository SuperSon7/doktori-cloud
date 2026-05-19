# -----------------------------------------------------------------------------
# IAM Policy for Parameter Store access
# -----------------------------------------------------------------------------
resource "aws_iam_policy" "parameter_store_read" {
  count = var.create_kms_and_iam ? 1 : 0

  name        = "${var.project_name}-${var.environment}-parameter-store-read"
  description = "Policy to read Parameter Store secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.parameter_store[0].arn
      },
    ]
  })
}
