variable "project_name" {
  description = "Project name for resource naming and tagging"
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

variable "state_bucket" {
  description = "S3 bucket for Terraform remote state"
  type        = string
  default     = "doktori-v2-terraform-state"
}
