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

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
}

variable "dev_app_instance_type" {
  description = "Dev app EC2 instance type"
  type        = string
  default     = "t4g.medium"
}

variable "dev_app_ami" {
  description = "Custom AMI for dev app (마이그레이션용, 빈 문자열이면 최신 Ubuntu ARM64 사용)"
  type        = string
  default     = ""
}

# monitoring_instance_type → terraform/monitoring/variables.tf 로 이동

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 60
}

variable "allowed_admin_cidrs" {
  description = "관리자 IP 목록 (SSH 접근용)"
  type        = list(string)
  default     = []
}

variable "state_bucket" {
  description = "S3 bucket for Terraform remote state"
  type        = string
  default     = "doktori-v2-terraform-state"
}
