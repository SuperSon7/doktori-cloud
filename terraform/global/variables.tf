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
  description = "Service repo names for deploy OIDC (ECR push, SSM). Cloud repo는 cloud_repo 변수로 별도 관리"
  type        = list(string)
  default = [
    "5-team-service-be",
    "5-team-service-fe",
    "5-team-service-ai",
  ]
}

variable "cloud_repo" {
  description = "Cloud repo name (for Terraform OIDC role)"
  type        = string
  default     = "5-team-service-cloud"
}

variable "budget_limit_amount" {
  description = "Monthly budget limit in USD"
  type        = string
  default     = "800"
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
    ella            = { groups = ["be"] }
    bruni           = { groups = ["be"] }
    doktori-cloud-h = { groups = ["cloud"] }
    doktori-cloud-v = { groups = ["cloud"] }
  }
}

