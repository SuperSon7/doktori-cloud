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
  default     = "doktori-prod"
}

variable "nginx_instance_type" {
  description = "Nginx EC2 instance type"
  type        = string
  default     = "t4g.micro"
}

variable "front_instance_type" {
  description = "Frontend EC2 instance type"
  type        = string
  default     = "t4g.small"
}

variable "api_instance_type" {
  description = "API EC2 instance type"
  type        = string
  default     = "t4g.small"
}

variable "chat_instance_type" {
  description = "Chat EC2 instance type"
  type        = string
  default     = "t4g.micro"
}

variable "ai_instance_type" {
  description = "AI EC2 instance type"
  type        = string
  default     = "t4g.small"
}

variable "db_instance_type" {
  description = "DB EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "db_volume_size" {
  description = "DB EBS volume size in GB"
  type        = number
  default     = 30
}

variable "custom_ami_id" {
  description = "Custom AMI ID (pre-baked). If empty, uses latest Ubuntu 22.04 arm64 from Canonical."
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Domain name for Nginx SSL and server_name"
  type        = string
  default     = "doktori.kr"
}

variable "state_bucket" {
  description = "S3 bucket for Terraform remote state"
  type        = string
  default     = "doktori-v2-terraform-state"
}

variable "monitoring_ip" {
  description = "Monitoring server EIP (Alloy remote_write + Loki push 대상)"
  type        = string
  default     = "13.125.29.187"
}
