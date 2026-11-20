variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "An explicit AWS account ID is required; no caller discovery."
  }
}
variable "region" {
  type = string
  validation {
    condition     = can(regex("^(ap|us|eu|ca|sa|af|me|il|mx)-[a-z]+-[0-9]$", var.region))
    error_message = "This module supports the commercial aws partition only."
  }
}
variable "cluster_name" {
  type = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,40}$", var.cluster_name))
    error_message = "Use a cluster name of at most 40 letters, digits, underscore or hyphen."
  }
}
variable "issuer_url" {
  type = string
  validation {
    condition     = can(regex("^https://[a-zA-Z0-9.-]+(/[a-zA-Z0-9._-]+)*$", var.issuer_url))
    error_message = "Issuer must use HTTPS without port, query or trailing slash."
  }
}
variable "oidc_provider_arn" {
  description = "Existing global OIDC provider for issuer_url. Shared identity is not recreated by this module."
  type        = string
}
variable "join_parameter_name" {
  type = string
  validation {
    condition     = can(regex("^/[A-Za-z0-9_./-]+$", var.join_parameter_name))
    error_message = "An exact SSM path is required."
  }
}
variable "kms_key_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[a-f0-9-]+$", var.kms_key_arn))
    error_message = "Use an exact customer-managed KMS key ARN."
  }
}
variable "ami_ids" {
  type = set(string)
  validation {
    condition     = length(var.ami_ids) > 0 && alltrue([for id in var.ami_ids : can(regex("^ami-[0-9a-f]{17}$", id))])
    error_message = "At least one explicit AMI ID is required."
  }
}
variable "subnet_ids" {
  type = set(string)
  validation {
    condition     = length(var.subnet_ids) > 0 && alltrue([for id in var.subnet_ids : can(regex("^subnet-[0-9a-f]{17}$", id))])
    error_message = "At least one explicit subnet ID is required."
  }
}
variable "security_group_ids" {
  type = set(string)
  validation {
    condition     = length(var.security_group_ids) > 0 && alltrue([for id in var.security_group_ids : can(regex("^sg-[0-9a-f]{17}$", id))])
    error_message = "At least one explicit security group ID is required."
  }
}
variable "ecr_repository_arns" {
  description = "Explicit private ECR repositories this worker may pull. Public images need no ECR policy."
  type        = set(string)
  default     = []
}
