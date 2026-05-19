resource "aws_s3_bucket_versioning" "frontend_codedeploy_revisions" {
  bucket = aws_s3_bucket.frontend_codedeploy_revisions.id

  versioning_configuration {
    status = "Enabled"
  }
}
