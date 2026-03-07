variable "project_name" {
  type    = string
  default = "doktori"
}

# NOTE: "nonprod" — 기존 리소스 이름과 일치하도록 유지
variable "environment" {
  type    = string
  default = "nonprod"
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
  default = "doktori-dev"
}
