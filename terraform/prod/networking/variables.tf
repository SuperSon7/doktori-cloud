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

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet"
  type        = string
  default     = "10.1.0.0/22"
}

variable "private_app_subnet_cidr" {
  description = "CIDR block for private app subnet"
  type        = string
  default     = "10.1.16.0/20"
}

variable "private_db_subnet_cidr" {
  description = "CIDR block for private DB subnet"
  type        = string
  default     = "10.1.32.0/24"
}

variable "private_rds_subnet_cidr" {
  description = "CIDR block for private RDS subnet"
  type        = string
  default     = "10.1.40.0/24"
}

variable "availability_zone" {
  description = "Availability zone"
  type        = string
  default     = "ap-northeast-2a"
}

variable "rds_availability_zone" {
  description = "Availability zone for RDS private subnet"
  type        = string
  default     = "ap-northeast-2c"
}

variable "nat_instance_type" {
  description = "NAT instance type"
  type        = string
  default     = "t4g.nano"
}
