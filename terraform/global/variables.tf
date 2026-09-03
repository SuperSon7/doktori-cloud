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

variable "deploy_repos" {
  description = "GitHub repositories allowed to assume the deploy role through OIDC"
  type = list(object({
    owner = string
    repo  = string
  }))
  default = [
    {
      owner = "SuperSon7"
      repo  = "doktori-backend"
    },
    {
      owner = "SuperSon7"
      repo  = "doktori-frontend"
    },
    {
      owner = "SuperSon7"
      repo  = "doktori-ai"
    },
    {
      owner = "SuperSon7"
      repo  = "doktori-cloud"
    },
  ]
}

variable "deploy_role_environments" {
  description = "GitHub environments allowed to assume the deploy role"
  type        = set(string)
  default     = ["dev", "staging", "prod"]
}

variable "terraform_repos" {
  description = "GitHub owner/repo pairs allowed to assume the Terraform role"
  type = list(object({
    owner = string
    repo  = string
  }))
  default = [
    {
      owner = "SuperSon7"
      repo  = "doktori-cloud"
    },
  ]
}

variable "terraform_role_environments" {
  description = "GitHub environments allowed to assume the Terraform role"
  type        = set(string)
  default = [
    "terraform-dev",
    "terraform-prod",
    "terraform-shared",
    "terraform-staging",
  ]
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
