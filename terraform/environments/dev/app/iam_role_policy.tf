resource "aws_iam_role_policy" "batch_start_lambda" {
  name = "${var.project_name}-${var.environment}-start-weekly-batch"
  role = aws_iam_role.batch_start_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:StartInstances",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.batch_start_lambda.arn}:*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "batch_start_scheduler" {
  name = "${var.project_name}-${var.environment}-weekly-batch-scheduler"
  role = aws_iam_role.batch_start_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.batch_start.arn
      },
    ]
  })
}
