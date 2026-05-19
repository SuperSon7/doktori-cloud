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

variable "enable_data_ha" {
  description = "Whether to run Redis/RabbitMQ as 3-node HA clusters. false keeps the first apply small with single data nodes."
  type        = bool
  default     = false
}

variable "key_name" {
  type    = string
  default = ""
}

variable "redis_ami_id" {
  description = "AMI ID for Redis EC2. Must be a concrete Packer AMI ID; do not fall back to raw Ubuntu."
  type        = string
  # packer:redis_ami_id
  default = "ami-050bbedf56a6fd0fe"

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.redis_ami_id))
    error_message = "redis_ami_id must be a concrete Packer AMI ID; do not fall back to a raw Ubuntu AMI."
  }
}

variable "rabbitmq_ami_id" {
  description = "AMI ID for RabbitMQ EC2. Must be a concrete Packer AMI ID; do not fall back to raw Ubuntu."
  type        = string
  # packer:rabbitmq_ami_id
  default = "ami-03038a0d90637491a"

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.rabbitmq_ami_id))
    error_message = "rabbitmq_ami_id must be a concrete Packer AMI ID; do not fall back to a raw Ubuntu AMI."
  }
}

variable "mongodb_ami_id" {
  description = "AMI ID for MongoDB EC2. Must be a concrete Packer AMI ID; do not fall back to raw Ubuntu."
  type        = string
  # packer:mongodb_ami_id
  default = "ami-0aa5b5ca4b13ac1ba"

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.mongodb_ami_id))
    error_message = "mongodb_ami_id must be a concrete Packer AMI ID; do not fall back to a raw Ubuntu AMI."
  }
}


variable "db_engine_version" {
  type    = string
  default = "8.4.8"
}

variable "db_parameter_group_family" {
  type    = string
  default = "mysql8.4"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_max_allocated_storage" {
  type    = number
  default = 100
}

variable "db_name" {
  type    = string
  default = "doktori"
}

variable "db_username" {
  type    = string
  default = "admin"
}

variable "db_backup_retention" {
  type    = number
  default = 7
}
