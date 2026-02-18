variable "project_name" {
  description = "Project name"
  type        = string
  default     = "doktori"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
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
  default     = "t3.small"
}

variable "bastion_instance_type" {
  description = "Bastion EC2 instance type"
  type        = string
  default     = "t3.micro"
}

# monitoring_instance_type → terraform/monitoring/variables.tf 로 이동

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "state_bucket" {
  description = "S3 bucket for Terraform remote state"
  type        = string
  default     = "doktori-v2-terraform-state"
}
