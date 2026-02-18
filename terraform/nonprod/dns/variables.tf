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

variable "state_bucket" {
  description = "S3 bucket for Terraform remote state"
  type        = string
  default     = "doktori-v2-terraform-state"
}

variable "dev_app_ip" {
  description = "Dev app public IP (bastion or NAT EIP for port forwarding)"
  type        = string
}

variable "monitoring_ip" {
  description = "Monitoring public IP"
  type        = string
}
