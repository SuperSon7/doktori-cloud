# -----------------------------------------------------------------------------
# S3 Buckets (for_each)
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "this" {
  for_each = var.s3_buckets
  bucket   = each.value.bucket_name

  tags = {
    Name    = each.value.bucket_name
    Service = "storage"
  }

  lifecycle {
    prevent_destroy = true
  }
}
