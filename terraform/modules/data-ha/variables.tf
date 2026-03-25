# =============================================================================
# Data HA Module — Variables
# Redis Sentinel (3-node) + RabbitMQ Quorum Queue (3-node) co-located
# =============================================================================

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

# --- Networking ---

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "subnet_ids" {
  description = "List of subnet IDs across AZs for node placement (min 2, ideally 3)"
  type        = list(string)
}

# --- Route53 ---

variable "internal_zone_id" {
  description = "Route53 private hosted zone ID"
  type        = string
}

variable "internal_domain" {
  description = "Internal domain name (e.g. staging.doktori.internal)"
  type        = string
}

# --- Compute ---

variable "node_count" {
  description = "Number of data nodes (must be odd, minimum 3 for quorum)"
  type        = number
  default     = 3

  validation {
    condition     = var.node_count >= 3 && var.node_count % 2 == 1
    error_message = "node_count must be odd and >= 3 for quorum."
  }
}

variable "instance_type" {
  description = "EC2 instance type for data nodes (min t4g.small for co-located Redis+RabbitMQ)"
  type        = string
  default     = "t4g.small"
}

variable "volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 20
}

variable "ami_id" {
  description = "AMI ID (empty = latest Ubuntu 22.04 ARM64)"
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key pair name (empty = no SSH key)"
  type        = string
  default     = ""
}

# --- SSM Parameter Names (credentials) ---

variable "redis_password_ssm" {
  description = "SSM parameter name for Redis password"
  type        = string
}

variable "rabbitmq_user_ssm" {
  description = "SSM parameter name for RabbitMQ username"
  type        = string
}

variable "rabbitmq_pass_ssm" {
  description = "SSM parameter name for RabbitMQ password"
  type        = string
}

variable "rabbitmq_cookie_ssm" {
  description = "SSM parameter name for Erlang cookie (empty = use default)"
  type        = string
  default     = ""
}

# --- Redis Tuning ---

variable "redis_maxmemory" {
  description = "Redis maxmemory setting"
  type        = string
  default     = "256mb"
}

variable "sentinel_down_after_ms" {
  description = "Sentinel down-after-milliseconds"
  type        = number
  default     = 5000
}

# --- Tags ---

variable "extra_tags" {
  description = "Additional tags for all resources"
  type        = map(string)
  default     = {}
}