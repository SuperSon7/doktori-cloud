variable "project_name" {
  description = "Project name"
  type        = string
  default     = "doktori"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "Primary AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "state_bucket" {
  description = "Terraform remote state bucket"
  type        = string
  default     = "doktori-v2-terraform-state"
}

variable "domain_name" {
  description = "Root domain name kept for reference"
  type        = string
  default     = "doktori.kr"
}

variable "dev_domain_name" {
  description = "Public development domain served by CloudFront"
  type        = string
  default     = "dev.doktori.kr"
}

variable "ssr_origin_domain" {
  description = "Origin domain name for the dev Next/Nginx server. Do not set this to the CloudFront alias."
  type        = string
}

variable "ssr_origin_protocol_policy" {
  description = "Protocol policy used by CloudFront to connect to the dev SSR origin"
  type        = string
  default     = "https-only"

  validation {
    condition     = contains(["http-only", "https-only", "match-viewer"], var.ssr_origin_protocol_policy)
    error_message = "ssr_origin_protocol_policy must be one of: http-only, https-only, match-viewer."
  }
}

variable "create_dns_record" {
  description = "Deprecated. DNS is managed outside this Terraform stack."
  type        = bool
  default     = false
}

variable "create_acm_certificate" {
  description = "Whether to create a us-east-1 ACM certificate in this account. DNS validation must be completed outside Terraform."
  type        = bool
  default     = false
}

variable "acm_cert_arn" {
  description = "Existing us-east-1 ACM certificate ARN for the dev alias. Required when create_acm_certificate is false."
  type        = string
  default     = null
}

variable "next_image_default_ttl" {
  description = "Default TTL for Next image optimization responses"
  type        = number
  default     = 86400
}

variable "next_image_max_ttl" {
  description = "Max TTL for Next image optimization responses"
  type        = number
  default     = 31536000
}
