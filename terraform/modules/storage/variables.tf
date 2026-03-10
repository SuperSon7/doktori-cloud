variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "s3_buckets" {
  description = "Map of S3 buckets to create"
  type = map(object({
    bucket_name        = string
    public_read        = optional(bool, false)
    public_read_prefix = optional(string, "/*")   # e.g. "/images/*" for partial public read
    versioning         = optional(bool, false)
    enable_cors        = optional(bool, false)
    encryption         = optional(bool, false)
    bucket_key_enabled = optional(bool, false)
    folders            = optional(list(string), [])
  }))
  default = {}
}

variable "create_kms_and_iam" {
  description = "Whether to create KMS key and IAM policy for Parameter Store"
  type        = bool
  default     = true
}

variable "ecr_repositories" {
  description = "Map of ECR repositories to create"
  type = map(object({
    name = string
  }))
  default = {}
}
