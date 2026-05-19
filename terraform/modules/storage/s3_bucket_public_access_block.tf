resource "aws_s3_bucket_public_access_block" "this" {
  for_each = var.s3_buckets
  bucket   = aws_s3_bucket.this[each.key].id

  block_public_acls       = !each.value.public_read
  block_public_policy     = !each.value.public_read
  ignore_public_acls      = !each.value.public_read
  restrict_public_buckets = !each.value.public_read
}
