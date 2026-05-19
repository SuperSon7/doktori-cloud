resource "aws_s3_bucket_policy" "this" {
  for_each = { for k, v in var.s3_buckets : k => v if v.public_read }
  bucket   = aws_s3_bucket.this[each.key].id

  depends_on = [aws_s3_bucket_public_access_block.this]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadImages"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.this[each.key].arn}${each.value.public_read_prefix}"
      }
    ]
  })
}
