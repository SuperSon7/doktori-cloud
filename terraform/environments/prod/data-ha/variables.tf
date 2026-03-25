variable "project_name" {
  type    = string
  default = "doktori"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "state_bucket" {
  type    = string
  default = "doktori-v2-terraform-state"
}

variable "key_name" {
  type    = string
  default = "doktori-prod"
}

variable "instance_type" {
  description = "Instance type for data nodes. t4g.small(2GB) is minimum for co-located Redis+RabbitMQ."
  type        = string
  default     = "t4g.small"
}