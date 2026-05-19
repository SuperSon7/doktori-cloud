resource "aws_s3_bucket_public_access_block" "frontend_codedeploy_revisions" {
  bucket = aws_s3_bucket.frontend_codedeploy_revisions.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
