resource "aws_iam_role" "frontend_codedeploy_service" {
  name = "${local.frontend_codedeploy_application_name}-service-role"

  tags = { Name = "${local.frontend_codedeploy_application_name}-service-role" }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "codedeploy.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}
