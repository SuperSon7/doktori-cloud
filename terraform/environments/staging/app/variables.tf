variable "project_name" {
  type    = string
  default = "doktori"
}

variable "environment" {
  type    = string
  default = "staging"
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
  default = "doktori-prod"
}

# --- Instance specs (overridable for load testing) ---

variable "instance_types" {
  description = "Instance type per service. Override with prod-spec.tfvars for load testing."
  type        = map(string)
  default = {
    nginx          = "t4g.nano"
    front          = "t4g.small"
    api            = "t4g.medium"
    chat           = "t4g.medium"
    ai             = "t4g.micro"
    rds_monitoring = "t3.micro"
    redis          = "t4g.micro"
    rabbitmq       = "t4g.micro"
  }
}

variable "default_volume_size" {
  description = "Default EBS volume size in GB"
  type        = number
  default     = 8
}

variable "create_h_k8s_nodes" {
  description = "Whether to create the learning-purpose h-k8s kubeadm nodes in staging"
  type        = bool
  default     = true
}

variable "h_k8s_instance_types" {
  description = "Instance type per h-k8s node"
  type        = map(string)
  default = {
    master   = "t4g.medium"
    worker_1 = "t4g.large"
    worker_2 = "t4g.large"
  }
}

variable "h_k8s_volume_sizes" {
  description = "Root volume size per h-k8s node in GB"
  type        = map(number)
  default = {
    master   = 30
    worker_1 = 50
    worker_2 = 50
  }
}
