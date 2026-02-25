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

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet"
  type        = string
  default     = "10.0.0.0/22"
}

variable "private_app_subnet_cidr" {
  description = "CIDR block for private app subnet"
  type        = string
  default     = "10.0.16.0/20"
}

variable "private_db_subnet_cidr" {
  description = "CIDR block for private DB subnet"
  type        = string
  default     = "10.0.32.0/24"
}

variable "availability_zone" {
  description = "Availability zone"
  type        = string
  default     = "ap-northeast-2a"
}

# ── NAT Instance ────────────────────────────────────────────────
variable "nat_instance_type" {
  description = "NAT instance type (t4g.nano: ~$3/월, dev에 충분)"
  type        = string
  default     = "t4g.nano"
}

variable "nat_key_name" {
  description = "NAT instance SSH key pair name (디버깅용)"
  type        = string
  default     = "doktori-dev"
}
