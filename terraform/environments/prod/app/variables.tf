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

variable "domain_name" {
  type    = string
  default = "doktori.kr"
}

variable "monitoring_ip" {
  type    = string
  default = "13.125.29.187"
}
