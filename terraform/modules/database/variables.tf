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

variable "db_subnet_ids" {
  description = "List of subnet IDs for the DB subnet group (must span 2+ AZs)"
  type        = list(string)
}

variable "db_engine_version" {
  type    = string
  default = "8.0.45"
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
  default = "doktoridb"
}

variable "db_username" {
  type    = string
  default = "admin"
}

variable "db_backup_retention" {
  type    = number
  default = 7
}

variable "db_availability_zone" {
  type    = string
  default = "ap-northeast-2a"
}

variable "db_extra_parameters" {
  description = "Additional DB parameter group parameters"
  type = list(object({
    name         = string
    value        = string
    apply_method = optional(string, "immediate")
  }))
  default = []
}
