variable "project_name" {
  type    = string
  default = "doktori"
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

variable "key_name" {
  type    = string
  default = "doktori-prod"
}

# --- Instance specs (overridable for load testing) ---

variable "instance_types" {
  description = "Instance type per service. Override with prod-spec.tfvars for load testing."
  type        = map(string)
  default = {
    nginx          = "t4g.nano"
    front          = "t4g.nano"
    api            = "t4g.nano"
    chat           = "t4g.micro"
    ai             = "t4g.micro"
    rds_monitoring = "t3.micro"
  }
}

variable "default_volume_size" {
  description = "Default EBS volume size in GB"
  type        = number
  default     = 8
}
