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


variable "key_name" {
  type    = string
  default = "doktori-prod"
}

variable "domain_name" {
  type    = string
  default = "doktori.kr"
}

variable "chat_observer_allowed_cidrs" {
  description = "CIDR blocks allowed to access the chat observer over HTTPS"
  type        = list(string)
  default     = []
}

variable "chat_observer_instance_type" {
  description = "Instance type for the public chat observer host"
  type        = string
  default     = "t3.small"
}
