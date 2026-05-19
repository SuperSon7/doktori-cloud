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

variable "dev_app_ami_id" {
  description = "AMI ID for dev Docker Compose host instances. Must be a concrete Packer dev-app AMI ID."
  type        = string
  # packer:dev_app_ami_id
  default = "ami-05a601bc547b01211"

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.dev_app_ami_id))
    error_message = "dev_app_ami_id must be a concrete Packer dev-app AMI ID; do not fall back to a raw Ubuntu AMI."
  }
}

variable "dev_ai_ami_id" {
  description = "AMI ID for dev AI host instances. Empty keeps the previous dev-app AMI until the dev-ai Packer AMI is built."
  type        = string
  # packer:dev_ai_ami_id
  default = "ami-00b0bbaaafadaaaa9"

  validation {
    condition     = var.dev_ai_ami_id == "" || can(regex("^ami-[0-9a-f]{8,17}$", var.dev_ai_ami_id))
    error_message = "dev_ai_ami_id must be empty or a concrete Packer dev-ai AMI ID."
  }
}

variable "frontend_ami_id" {
  description = "AMI ID for the dev frontend EC2. Packer-built frontend image."
  type        = string
  # packer:frontend_ami_id
  default = "ami-073134625384eb471"

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.frontend_ami_id))
    error_message = "frontend_ami_id must be a concrete Packer AMI ID."
  }
}

variable "app_instance_type" {
  description = "Instance type for the dev app EC2"
  type        = string
  default     = "t4g.medium"
}

variable "front_instance_type" {
  description = "Instance type for the dev frontend EC2"
  type        = string
  default     = "t4g.small"
}

variable "ai_instance_type" {
  description = "Instance type for the dev AI EC2"
  type        = string
  default     = "t4g.medium"
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
  description = "SSM parameter path — batch 및 qdrant 컨테이너에 공통 주입. 기본값: /{project_name}/{environment}"
  type        = string
  default     = null
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
