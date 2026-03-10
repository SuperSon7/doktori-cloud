# -----------------------------------------------------------------------------
# S3 Buckets (for_each)
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "this" {
  for_each = var.s3_buckets
  bucket   = each.value.bucket_name

  tags = {
    Name       = each.value.bucket_name
    Service    = "storage"
    CostCenter = "app"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = var.s3_buckets
  bucket   = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = each.value.versioning ? "Enabled" : "Disabled"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = var.s3_buckets
  bucket   = aws_s3_bucket.this[each.key].id

  block_public_acls       = !each.value.public_read
  block_public_policy     = !each.value.public_read
  ignore_public_acls      = !each.value.public_read
  restrict_public_buckets = !each.value.public_read
}

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

# S3 folder objects
locals {
  s3_folders = flatten([
    for bucket_key, bucket in var.s3_buckets : [
      for folder in bucket.folders : {
        bucket_key = bucket_key
        folder     = folder
      }
    ]
  ])
}

resource "aws_s3_object" "folders" {
  for_each = { for f in local.s3_folders : "${f.bucket_key}/${f.folder}" => f }

  bucket       = aws_s3_bucket.this[each.value.bucket_key].id
  key          = each.value.folder
  content_type = "application/x-directory"
}

# -----------------------------------------------------------------------------
# ECR Repositories (for_each)
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "this" {
  for_each = var.ecr_repositories

  name                 = each.value.name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name    = each.value.name
    Service = each.key
  }
}

resource "aws_ecr_lifecycle_policy" "cleanup" {
  for_each = var.ecr_repositories

  repository = aws_ecr_repository.this[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# KMS Key for Parameter Store
# -----------------------------------------------------------------------------
resource "aws_kms_key" "parameter_store" {
  count = var.create_kms_and_iam ? 1 : 0

  description             = "KMS key for ${var.environment} Parameter Store secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name       = "${var.project_name}-${var.environment}-parameter-store-key"
    CostCenter = "infra"
  }
}

resource "aws_kms_alias" "parameter_store" {
  count = var.create_kms_and_iam ? 1 : 0

  name          = "alias/${var.project_name}-${var.environment}-parameter-store"
  target_key_id = aws_kms_key.parameter_store[0].key_id
}

# -----------------------------------------------------------------------------
# IAM Policy for Parameter Store access
# -----------------------------------------------------------------------------
resource "aws_iam_policy" "parameter_store_read" {
  count = var.create_kms_and_iam ? 1 : 0

  name        = "${var.project_name}-${var.environment}-parameter-store-read"
  description = "Policy to read ${var.environment} Parameter Store secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.parameter_store[0].arn
      },
    ]
  })
}
