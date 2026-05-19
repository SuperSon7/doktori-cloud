resource "aws_s3_bucket_policy" "static" {
  bucket = aws_s3_bucket.static.id
  policy = data.aws_iam_policy_document.static_bucket_policy.json
}
