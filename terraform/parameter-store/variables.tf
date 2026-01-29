variable "project_name" {
  description = "Project name"
  type        = string
  default     = "doktori"
}

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

# -----------------------------------------------------------------------------
# NOTE: Secret variables have been removed.
# Secrets are now managed outside of Terraform using AWS CLI.
# See scripts/create-secrets.sh for secret management.
# -----------------------------------------------------------------------------
