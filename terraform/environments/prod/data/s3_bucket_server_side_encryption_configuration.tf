resource "aws_s3_bucket_server_side_encryption_configuration" "frontend_codedeploy_revisions" {
  bucket = aws_s3_bucket.frontend_codedeploy_revisions.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
