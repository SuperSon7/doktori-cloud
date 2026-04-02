variable "project_name" {
  description = "Project name"
  type        = string
  default     = "doktori"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "domain_name" {
  description = "Root domain name"
  type        = string
  default     = "doktori.kr"
}
