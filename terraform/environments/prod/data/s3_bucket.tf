resource "aws_s3_bucket" "frontend_codedeploy_revisions" {
  bucket = local.codedeploy_revision_bucket_name

  tags = {
    Name = local.codedeploy_revision_bucket_name
  }

  lifecycle {
    prevent_destroy = true
  }
}
