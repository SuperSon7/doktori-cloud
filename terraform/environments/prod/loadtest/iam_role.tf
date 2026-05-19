resource "aws_iam_role" "k6_runner" {
  name = "${var.project_name}-${var.environment}-k6-runner"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-k6-runner-role"
  }
}
