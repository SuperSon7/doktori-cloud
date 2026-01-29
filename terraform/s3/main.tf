terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "doktori-terraform-state"
    key            = "s3/terraform.tfstate"
    region         = "ap-northeast-2"
    encrypt        = true
    dynamodb_table = "doktori-terraform-locks"
  }
}

locals {
  environment = var.environment
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = local.environment
      ManagedBy   = "Terraform"
    }
  }
}

# -----------------------------------------------------------------------------
# S3 Bucket for Images
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "images" {
  bucket = "${var.project_name}-${local.environment}-images"

  tags = {
    Name = "${var.project_name}-${local.environment}-images"
  }
}

resource "aws_s3_bucket_versioning" "images" {
  bucket = aws_s3_bucket.images.id
  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_public_access_block" "images" {
  bucket = aws_s3_bucket.images.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Public read policy for GET requests
resource "aws_s3_bucket_policy" "images_public_read" {
  bucket = aws_s3_bucket.images.id

  depends_on = [aws_s3_bucket_public_access_block.images]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.images.arn}/*"
      }
    ]
  })
}

# CORS configuration for browser access (presigned URL upload)
resource "aws_s3_bucket_cors_configuration" "images" {
  bucket = aws_s3_bucket.images.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD", "PUT"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# -----------------------------------------------------------------------------
# Folder structure (empty objects as placeholders)
# -----------------------------------------------------------------------------
resource "aws_s3_object" "profiles_folder" {
  bucket = aws_s3_bucket.images.id
  key    = "images/profiles/"
  content_type = "application/x-directory"
}

resource "aws_s3_object" "meetings_folder" {
  bucket = aws_s3_bucket.images.id
  key    = "images/meetings/"
  content_type = "application/x-directory"
}

# -----------------------------------------------------------------------------
# IAM User for Developer local access
# -----------------------------------------------------------------------------
resource "aws_iam_user" "s3_developer" {
  name = "${var.project_name}-${local.environment}-s3-developer"

  tags = {
    Name = "${var.project_name}-${local.environment}-s3-developer"
  }
}

resource "aws_iam_user_policy" "s3_developer" {
  name = "${var.project_name}-${local.environment}-s3-developer"
  user = aws_iam_user.s3_developer.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.images.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.images.arn
      }
    ]
  })
}

resource "aws_iam_access_key" "s3_developer" {
  user = aws_iam_user.s3_developer.name
}