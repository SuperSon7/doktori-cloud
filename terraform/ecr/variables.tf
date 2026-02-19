variable "project_name" {
  description = "Project name for resource naming and tagging"
  type        = string
  default     = "doktori"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "shared"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "repositories" {
  description = "List of ECR repository names to create"
  type        = list(string)
  default = [
    "doktori/backend-api",
    "doktori/backend-chat"
  ]
}

variable "image_retention_count" {
  description = "Number of recent images to keep per repository"
  type        = number
  default     = 10
}
