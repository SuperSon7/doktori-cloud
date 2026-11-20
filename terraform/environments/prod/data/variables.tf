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
  description = "Legacy switch for Redis and RabbitMQ HA. Prefer the per-service switches for staged migration."
  type        = bool
  default     = false
}

variable "enable_redis_ha" {
  description = "Run Redis primary, two replicas and three Sentinels across AZs."
  type        = bool
  default     = false
}

variable "ha_ami_ids" {
  description = "Explicit reviewed AMIs for enabled HA services. Existing single-node AMI defaults are not silently reused for a new HA rollout. Build/review images first; no image existence/version claim is made by this validation."
  type        = map(string)
  default     = {}
  validation {
    condition = alltrue([
      for service, enabled in {
        redis    = var.enable_data_ha || var.enable_redis_ha
        rabbitmq = var.enable_data_ha || var.enable_rabbitmq_ha
        mongodb  = var.enable_mongodb_ha
      } : !enabled || can(regex("^ami-([0-9a-f]{8}|[0-9a-f]{17})$", lookup(var.ha_ami_ids, service, "")))
    ])
    error_message = "Set a reviewed concrete ha_ami_ids entry for every enabled HA service. Do not reuse an unverified old AMI by default."
  }
}

variable "allow_redis_initial_primary" {
  description = "Allow initial redis-a bootstrap without Sentinel discovery. Use only for the first HA setup, then turn off."
  type        = bool
  default     = false
}

variable "enable_rabbitmq_ha" {
  description = "Run three RabbitMQ nodes. Existing quorum queue membership must also be expanded."
  type        = bool
  default     = false
}

variable "enable_mongodb_ha" {
  description = "Run a three-data-member MongoDB replica set across AZs."
  type        = bool
  default     = false
}

variable "mongodb_replica_set_name" {
  type    = string
  default = "doktori-rs"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_-]{0,62}$", var.mongodb_replica_set_name))
    error_message = "Replica set name must start with a letter and contain only letters, digits, underscores or hyphens."
  }
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
variable "enable_data_ha_observability" {
  description = "Prepare Sentinel/quorum monitoring, least-privilege identities and HA inventory. No monitoring server deployment."
  type        = bool
  default     = false
}

variable "data_ha_remote_write_url" {
  type    = string
  default = "http://monitoring.mgmt.doktori.internal:9090/api/v1/write"
}

variable "data_ha_loki_push_url" {
  type    = string
  default = "http://monitoring.mgmt.doktori.internal:3100/loki/api/v1/push"
}
