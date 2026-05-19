resource "aws_iam_role_policy" "loki_s3" {
  name = "${var.project_name}-monitoring-loki-s3"
  role = aws_iam_role.monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ]
      Resource = [
        local.data.loki_bucket_arn,
        "${local.data.loki_bucket_arn}/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "cloudwatch_read" {
  name = "${var.project_name}-monitoring-cloudwatch-read"
  role = aws_iam_role.monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListMetrics",
        "cloudwatch:DescribeAlarms"
      ]
      Resource = "*"
    }]
  })
}
