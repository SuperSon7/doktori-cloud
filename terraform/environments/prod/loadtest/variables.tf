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

variable "runner_count" {
  description = "Number of k6 runner instances"
  type        = number
  default     = 6
}

variable "instance_type" {
  description = "EC2 instance type for k6 runners"
  type        = string
  default     = "t4g.medium"
}

variable "root_volume_size" {
  description = "Root volume size in GiB"
  type        = number
  default     = 20
}

variable "runner_ami_id" {
  description = "Prebaked loadtest runner AMI ID. 비어 있으면 Canonical Ubuntu로 fallback"
  type        = string
  default     = ""
}
