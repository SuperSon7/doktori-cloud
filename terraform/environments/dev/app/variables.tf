variable "project_name" {
  type    = string
  default = "doktori"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
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

variable "ssm_parameter_path" {
  description = "SSM parameter path — batch 및 qdrant 컨테이너에 공통 주입"
  type        = string
  default     = "/doktori/dev"
}

variable "batch_container_command" {
  description = "Command passed to the batch container"
  type        = list(string)
  default     = ["python", "-m", "app.batch.weekly_batch"]
}

variable "qdrant_instance_type" {
  description = "Instance type for the dev Qdrant EC2"
  type        = string
  default     = "t4g.small"
}

variable "qdrant_volume_size" {
  description = "Root volume size in GiB for the dev Qdrant EC2"
  type        = number
  default     = 30
}

variable "qdrant_image" {
  description = "Container image used for the dev Qdrant instance"
  type        = string
  default     = "qdrant/qdrant:v1.13.6"
}

