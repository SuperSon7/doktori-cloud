# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "availability_zone" {
  description = "Availability zone for subnet"
  type        = string
  default     = "ap-northeast-2a"
}

# -----------------------------------------------------------------------------
# EC2
# -----------------------------------------------------------------------------
variable "instance_type" {
  description = "EC2 instance type (t3.small = 2 vCPU, 2GB RAM)"
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "Name of existing EC2 Key Pair for SSH access"
  type        = string
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "root_volume_type" {
  description = "Root EBS volume type"
  type        = string
  default     = "gp3"
}

# -----------------------------------------------------------------------------
# Security
# -----------------------------------------------------------------------------
variable "allowed_admin_cidrs" {
  description = "CIDR blocks allowed for SSH and monitoring access"
  type        = list(string)
  default     = ["211.244.225.166/32", "211.244.225.211/32"]
}

variable "monitoring_server_ips" {
  description = "Monitoring server IPs for metric scraping access"
  type        = list(string)
  default     = ["3.36.172.142/32", "3.37.104.151/32"]
}

# -----------------------------------------------------------------------------
# Application Ports
# -----------------------------------------------------------------------------
variable "frontend_port" {
  description = "Frontend application port"
  type        = number
  default     = 3000
}

variable "backend_port" {
  description = "Backend application port"
  type        = number
  default     = 8080
}

variable "ai_port" {
  description = "AI service port"
  type        = number
  default     = 8000
}
