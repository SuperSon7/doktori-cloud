variable "project_name" {
  type    = string
  default = "doktori"
}

variable "project_tag" {
  type    = string
  default = "doktori-loadtest"
}

variable "environment" {
  type    = string
  default = "staging"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "state_bucket" {
  type    = string
  default = "doktori-v2-terraform-state"
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
