resource "aws_s3_object" "folders" {
  for_each = { for f in local.s3_folders : "${f.bucket_key}/${f.folder}" => f }

  bucket       = aws_s3_bucket.this[each.value.bucket_key].id
  key          = each.value.folder
  content_type = "application/x-directory"
}
