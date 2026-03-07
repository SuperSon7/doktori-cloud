variable "project_name" {
  description = "Project name"
  type        = string
  default     = "doktori"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "static_bucket_name" {
  description = "S3 bucket name for static assets"
  type        = string
}

variable "ssr_origin_domain" {
  description = "SSR origin domain (Nginx public DNS/EIP)"
  type        = string
}

variable "ssr_origin_protocol_policy" {
  description = "Protocol policy to connect to SSR origin"
  type        = string
  default     = "http-only"

  validation {
    condition     = contains(["http-only", "https-only", "match-viewer"], var.ssr_origin_protocol_policy)
    error_message = "ssr_origin_protocol_policy must be one of: http-only, https-only, match-viewer."
  }
}

variable "aliases" {
  description = "Optional CloudFront aliases (CNAMEs)"
  type        = list(string)
  default     = []
}

variable "acm_cert_arn" {
  description = "Optional ACM certificate ARN for aliases"
  type        = string
  default     = null
}
