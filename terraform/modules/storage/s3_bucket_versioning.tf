resource "aws_s3_bucket_versioning" "this" {
  for_each = var.s3_buckets
  bucket   = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = each.value.versioning ? "Enabled" : "Disabled"
  }
}
