# -----------------------------------------------------------------------------
# S3 Bucket (dev) - Consolidated single bucket
# Prefix-based structure: images/*, db-backup/*
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "main" {
  bucket = "${var.project_name}-v2-${var.environment}"

  tags = {
    Name       = "${var.project_name}-v2-${var.environment}"
    Service    = "storage"
    CostCenter = "app"
  }
}

resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "main" {
  bucket = aws_s3_bucket.main.id

  depends_on = [aws_s3_bucket_public_access_block.main]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadImages"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.main.arn}/images/*"
      }
    ]
  })
}

resource "aws_s3_bucket_cors_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD", "PUT"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Folder structure
resource "aws_s3_object" "profiles_folder" {
  bucket       = aws_s3_bucket.main.id
  key          = "images/profiles/"
  content_type = "application/x-directory"
}

resource "aws_s3_object" "meetings_folder" {
  bucket       = aws_s3_bucket.main.id
  key          = "images/meetings/"
  content_type = "application/x-directory"
}

resource "aws_s3_object" "db_backup_folder" {
  bucket       = aws_s3_bucket.main.id
  key          = "db-backup/"
  content_type = "application/x-directory"
}

# -----------------------------------------------------------------------------
# ECR Repositories
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "backend_api" {
  name                 = "${var.project_name}/backend-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name    = "${var.project_name}/backend-api"
    Service = "api"
    Part    = "be"
  }
}

resource "aws_ecr_repository" "backend_chat" {
  name                 = "${var.project_name}/backend-chat"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name    = "${var.project_name}/backend-chat"
    Service = "chat"
    Part    = "be"
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project_name}/frontend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name    = "${var.project_name}/frontend"
    Service = "front"
    Part    = "fe"
  }
}

resource "aws_ecr_repository" "ai" {
  name                 = "${var.project_name}/ai"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name    = "${var.project_name}/ai"
    Service = "ai"
    Part    = "ai"
  }
}

# ECR Lifecycle Policy - keep last 10 images per tag prefix
resource "aws_ecr_lifecycle_policy" "cleanup" {
  for_each = {
    backend_api  = aws_ecr_repository.backend_api.name
    backend_chat = aws_ecr_repository.backend_chat.name
    frontend     = aws_ecr_repository.frontend.name
    ai           = aws_ecr_repository.ai.name
  }

  repository = each.value

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
  description             = "KMS key for ${var.environment} Parameter Store secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name       = "${var.project_name}-${var.environment}-parameter-store-key"
    CostCenter = "infra"
  }
}

resource "aws_kms_alias" "parameter_store" {
  name          = "alias/${var.project_name}-${var.environment}-parameter-store"
  target_key_id = aws_kms_key.parameter_store.key_id
}

# -----------------------------------------------------------------------------
# IAM Policy for Parameter Store access
# -----------------------------------------------------------------------------
resource "aws_iam_policy" "parameter_store_read" {
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
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
        ]
        Resource = aws_kms_key.parameter_store.arn
      },
    ]
  })
}
