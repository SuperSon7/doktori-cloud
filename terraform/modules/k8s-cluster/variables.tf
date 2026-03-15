variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for NLB"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for master/worker ASGs"
  type        = list(string)
}

# --- Master ---
variable "master_instance_type" {
  type    = string
  default = "t4g.medium"
}

variable "master_desired" {
  type    = number
  default = 2
}

variable "master_volume_size" {
  type    = number
  default = 30
}

# --- Worker ---
variable "worker_instance_type" {
  type    = string
  default = "t4g.large"
}

variable "worker_desired" {
  type    = number
  default = 4
}

variable "worker_min" {
  type    = number
  default = 2
}

variable "worker_max" {
  type    = number
  default = 6
}

variable "worker_volume_size" {
  type    = number
  default = 50
}

variable "worker_node_port" {
  description = "NodePort for NLB target (NGF HTTP)"
  type        = number
  default     = 30080
}

# --- Common ---
variable "ami_id" {
  description = "AMI ID. If empty, uses latest Ubuntu 22.04 ARM64."
  type        = string
  default     = ""
}

variable "key_name" {
  type    = string
  default = ""
}

variable "iam_instance_profile_name" {
  type = string
}

variable "user_data_master" {
  description = "User data for master nodes"
  type        = string
  default     = ""
}

variable "user_data_worker" {
  description = "User data for worker nodes"
  type        = string
  default     = ""
}
