variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for ALB (minimum 2 AZs)"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ASG instances"
  type        = list(string)
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
}

variable "ami_id" {
  description = "AMI ID for frontend instances. If empty, uses latest Ubuntu 22.04 ARM64."
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
  default     = ""
}

variable "iam_instance_profile_name" {
  description = "IAM instance profile name (from compute module)"
  type        = string
}

variable "app_port" {
  description = "Application port (Next.js default: 3000)"
  type        = number
  default     = 3000
}

variable "health_check_path" {
  type    = string
  default = "/"
}

variable "desired_capacity" {
  type    = number
  default = 2
}

variable "min_size" {
  type    = number
  default = 2
}

variable "max_size" {
  type    = number
  default = 4
}

variable "volume_size" {
  type    = number
  default = 20
}

variable "user_data" {
  description = "User data script for frontend instances"
  type        = string
  default     = ""
}

variable "extra_sg_ids" {
  description = "Additional security group IDs to attach to instances"
  type        = list(string)
  default     = []
}