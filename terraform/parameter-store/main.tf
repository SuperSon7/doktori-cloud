terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    key = "parameter-store/terraform.tfstate"
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
# KMS Key for encrypting SecureString parameters
# -----------------------------------------------------------------------------
resource "aws_kms_key" "parameter_store" {
  description             = "KMS key for Parameter Store secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${var.project_name}-${local.environment}-parameter-store-key"
  }
}

resource "aws_kms_alias" "parameter_store" {
  name          = "alias/${var.project_name}-${local.environment}-parameter-store"
  target_key_id = aws_kms_key.parameter_store.key_id
}

# -----------------------------------------------------------------------------
# IAM Policy for accessing Parameter Store secrets
# -----------------------------------------------------------------------------
resource "aws_iam_policy" "parameter_store_read" {
  name        = "${var.project_name}-${local.environment}-parameter-store-read"
  description = "Policy to read Parameter Store secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${local.environment}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = aws_kms_key.parameter_store.arn
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# NOTE: Secrets are managed outside of Terraform for security reasons.
# Use the scripts/create-secrets.sh script to create/update secrets.
# This prevents sensitive values from being stored in Terraform state.
# -----------------------------------------------------------------------------
