variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "subnet_ids" {
  description = "Map of subnet key to subnet ID (from networking module)"
  type        = map(string)
}

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
  default     = ""
}

variable "custom_ami_id" {
  description = "Override ARM64 AMI for all services (empty = latest Ubuntu 22.04)"
  type        = string
  default     = ""
}

variable "services" {
  description = "Map of services to deploy"
  type = map(object({
    instance_type = string
    architecture  = string                    # "arm64" | "x86"
    subnet_key    = string                    # key into subnet_ids map
    volume_size   = optional(number, 20)
    associate_eip = optional(bool, false)
    user_data     = optional(string, "")
    ami_id        = optional(string, "")      # per-service AMI override
    tags          = optional(map(string), {})
    sg_ingress = list(object({
      description = string
      from_port   = number
      to_port     = number
      protocol    = string
      cidr_blocks = optional(list(string), [])
    }))
  }))
}

variable "sg_cross_rules" {
  description = "SG-to-SG ingress rules (inter-service references)"
  type = list(object({
    service_key = string # target SG
    source_key  = string # source SG
    from_port   = number
    to_port     = number
    protocol    = string
  }))
  default = []
}

variable "s3_bucket_arns" {
  description = "S3 bucket ARNs that EC2 instances can access"
  type        = list(string)
  default     = []
}

variable "ssm_parameter_paths" {
  description = "SSM Parameter Store paths (e.g. [\"/doktori/prod\"])"
  type        = list(string)
  default     = []
}

variable "enable_batch_self_stop" {
  description = "Whether to create ec2:StopInstances IAM policy for batch instances"
  type        = bool
  default     = false
}
