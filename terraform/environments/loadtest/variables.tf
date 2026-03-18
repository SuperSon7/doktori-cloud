variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI profile for the loadtest account"
  type        = string
  default     = ""
}

variable "project_name" {
  type    = string
  default = "doktori"
}

variable "runner_count" {
  description = "Number of k6 runner instances"
  type        = number
  default     = 3
}

variable "instance_type" {
  description = "EC2 instance type for k6 runners"
  type        = string
  default     = "t4g.small"
}

variable "root_volume_size" {
  description = "Root volume size in GiB"
  type        = number
  default     = 20
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.200.0.0/16"
}