resource "aws_iam_role_policy" "gha_cdn" {
  name = "${var.project_name}-gha-fe-cdn-prod"
  role = data.aws_iam_role.gha_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3BucketMeta"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.static.arn]
      },
      {
        Sid      = "S3ObjectWriteDelete"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.static.arn}/*"]
      },
      {
        Sid      = "CloudFrontInvalidation"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = [aws_cloudfront_distribution.cdn.arn]
      },
    ]
  })
}
