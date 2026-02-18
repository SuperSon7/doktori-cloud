variable "project_name" {
  description = "Project name"
  type        = string
  default     = "doktori"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "nonprod"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}
