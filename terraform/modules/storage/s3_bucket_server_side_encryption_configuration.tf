resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = { for k, v in var.s3_buckets : k => v if v.encryption }
  bucket   = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = each.value.bucket_key_enabled
  }
}
