variable "project_name" {
  description = "Project name"
  type        = string
  default     = "doktori"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
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

variable "nginx_instance_type" {
  description = "Nginx EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "front_instance_type" {
  description = "Frontend EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "api_instance_type" {
  description = "API EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "chat_instance_type" {
  description = "Chat EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "ai_instance_type" {
  description = "AI EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "state_bucket" {
  description = "S3 bucket for Terraform remote state"
  type        = string
  default     = "doktori-v2-terraform-state"
}
