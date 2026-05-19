resource "aws_s3_bucket_cors_configuration" "this" {
  for_each = { for k, v in var.s3_buckets : k => v if v.enable_cors }
  bucket   = aws_s3_bucket.this[each.key].id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD", "PUT"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}
