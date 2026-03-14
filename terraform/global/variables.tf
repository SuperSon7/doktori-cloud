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
  description = "GitHub repository names for deploy OIDC"
  type        = list(string)
  default = [
    "5-team-service-be",
    "5-team-service-fe",
    "5-team-service-ai",
    "5-team-service-cloud",
  ]
}

variable "cloud_repo" {
  description = "Cloud repo name (for Terraform OIDC role)"
  type        = string
  default     = "5-team-service-cloud"
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
  default = {
    ella  = { groups = ["be"] }
    bruni = { groups = ["be"] }
  }
}

variable "admin_users" {
  description = "Admin users (assigned to Admin group with AdministratorAccess)"
  type        = map(object({}))
  default = {
    doktori-admin   = {}
    doktori-cloud-h = {}
  }
}

variable "static_bucket_name" {
  description = "Static bucket name for CDN deployment permissions"
  type        = string
  default     = "doktori-prod-frontend-static"
}

variable "cloudfront_distribution_id" {
  description = "CloudFront distribution ID for invalidation permissions"
  type        = string
  default     = "EN4J9BGDSE4G0"
}
