variable "project_name" {
  description = "Project name"
  type        = string
  default     = "doktori"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "github_org" {
  description = "GitHub organization name"
  type        = string
  default     = "100-hours-a-week"
}

variable "github_repos" {
  description = "GitHub repository names for OIDC"
  type        = list(string)
  default = [
    "5-team-service-be",
    "5-team-service-fe",
    "5-team-service-ai",
  ]
}

variable "budget_limit_amount" {
  description = "Monthly budget limit in KRW"
  type        = string
  default     = "1000000"
}

variable "budget_alert_emails" {
  description = "Email addresses for budget alerts"
  type        = list(string)
  default     = ["cloud@doktori.kr"]
}

variable "team_members" {
  description = "Team members and their group assignments"
  type = map(object({
    groups = list(string)
  }))
  default = {}
}

variable "static_bucket_name" {
  description = "Static bucket name for CDN deployment permissions"
  type        = string
  default     = null
}

variable "cloudfront_distribution_id" {
  description = "CloudFront distribution ID for invalidation permissions"
  type        = string
  default     = null
}
