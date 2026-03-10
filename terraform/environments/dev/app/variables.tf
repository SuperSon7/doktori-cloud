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

variable "batch_instance_type" {
  description = "Instance type for the weekly batch EC2"
  type        = string
  default     = "t4g.large"
}

variable "batch_volume_size" {
  description = "Root volume size in GiB for the weekly batch EC2"
  type        = number
  default     = 50
}

variable "batch_image_repository" {
  description = "ECR repository path for the batch container image"
  type        = string
  default     = "doktori/ai"
}

variable "batch_image_tag" {
  description = "ECR image tag for the batch container image"
  type        = string
  default     = "develop"
}

variable "batch_ssm_parameter_path" {
  description = "SSM parameter path injected into the weekly batch container"
  type        = string
  default     = "/doktori/dev"
}

variable "batch_container_command" {
  description = "Command passed to the batch container"
  type        = list(string)
  default     = ["python", "-m", "app.batch.weekly_batch"]
}
