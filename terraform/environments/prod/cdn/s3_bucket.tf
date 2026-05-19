resource "aws_s3_bucket" "static" {
  bucket = var.static_bucket_name
}
