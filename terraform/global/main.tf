# -----------------------------------------------------------------------------
# GitHub OIDC Provider
# -----------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name = "${var.project_name}-github-actions-oidc"
  }
}

# -----------------------------------------------------------------------------
# GitHub Actions Deploy Role (OIDC)
# -----------------------------------------------------------------------------
locals {
  github_oidc_subjects = flatten([
    for repo in var.github_repos : [
      "repo:${var.github_org}/${repo}:ref:refs/heads/main",
      "repo:${var.github_org}/${repo}:ref:refs/heads/develop",
    ]
  ])
}

resource "aws_iam_role" "github_actions_deploy" {
  name        = "${var.project_name}-gha-deploy"
  description = "GitHub Actions deploy role for ${var.project_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = local.github_oidc_subjects
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-gha-deploy"
  }
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "${var.project_name}-gha-ecr"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:*:repository/${var.project_name}/*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "github_actions_ssm" {
  name = "${var.project_name}-gha-ssm"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
        ]
        Resource = "*"
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# SSM IAM Groups & Policies
# -----------------------------------------------------------------------------

# Cloud team - full access to all instances in all environments
resource "aws_iam_group" "cloud_team" {
  name = "${var.project_name}-cloud-team"
}

resource "aws_iam_group_policy" "cloud_team_ssm" {
  name  = "${var.project_name}-cloud-team-ssm"
  group = aws_iam_group.cloud_team.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:StartSession",
        ]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:*:instance/*",
        ]
        Condition = {
          StringEquals = {
            "ssm:resourceTag/Project" = var.project_name
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:TerminateSession",
          "ssm:ResumeSession",
        ]
        Resource = "arn:aws:ssm:*:*:session/$${aws:username}-*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:DescribeSessions",
          "ssm:GetConnectionStatus",
          "ssm:DescribeInstanceInformation",
          "ssm:DescribeInstanceProperties",
          "ec2:DescribeInstances",
        ]
        Resource = "*"
      },
    ]
  })
}

# BE team - api, chat, db in dev only
resource "aws_iam_group" "be_team" {
  name = "${var.project_name}-be-team"
}

resource "aws_iam_group_policy" "be_team_ssm" {
  name  = "${var.project_name}-be-team-ssm"
  group = aws_iam_group.be_team.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:StartSession",
        ]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:*:instance/*",
        ]
        Condition = {
          StringEquals = {
            "ssm:resourceTag/Service"     = ["app", "api", "chat", "db", "dev-app"]
            "ssm:resourceTag/Environment" = ["dev"]
            "ssm:resourceTag/Project"     = var.project_name
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:StartSession",
        ]
        Resource = [
          "arn:aws:ssm:${var.aws_region}::document/AWS-StartPortForwardingSession",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:TerminateSession",
          "ssm:ResumeSession",
        ]
        Resource = "arn:aws:ssm:*:*:session/$${aws:username}-*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:DescribeSessions",
          "ssm:GetConnectionStatus",
          "ssm:DescribeInstanceInformation",
          "ssm:DescribeInstanceProperties",
          "ec2:DescribeInstances",
        ]
        Resource = "*"
      },
    ]
  })
}

# FE team - front in dev only
resource "aws_iam_group" "fe_team" {
  name = "${var.project_name}-fe-team"
}

resource "aws_iam_group_policy" "fe_team_ssm" {
  name  = "${var.project_name}-fe-team-ssm"
  group = aws_iam_group.fe_team.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:StartSession",
        ]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:*:instance/*",
        ]
        Condition = {
          StringEquals = {
            "ssm:resourceTag/Service"     = ["front", "dev-app"]
            "ssm:resourceTag/Environment" = ["dev"]
            "ssm:resourceTag/Project"     = var.project_name
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:TerminateSession",
          "ssm:ResumeSession",
        ]
        Resource = "arn:aws:ssm:*:*:session/$${aws:username}-*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:DescribeSessions",
          "ssm:GetConnectionStatus",
          "ssm:DescribeInstanceInformation",
          "ssm:DescribeInstanceProperties",
          "ec2:DescribeInstances",
        ]
        Resource = "*"
      },
    ]
  })
}

# AI team - ai in dev only
resource "aws_iam_group" "ai_team" {
  name = "${var.project_name}-ai-team"
}

resource "aws_iam_group_policy" "ai_team_ssm" {
  name  = "${var.project_name}-ai-team-ssm"
  group = aws_iam_group.ai_team.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:StartSession",
        ]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:*:instance/*",
        ]
        Condition = {
          StringEquals = {
            "ssm:resourceTag/Service"     = ["ai", "dev-app"]
            "ssm:resourceTag/Environment" = ["dev"]
            "ssm:resourceTag/Project"     = var.project_name
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:TerminateSession",
          "ssm:ResumeSession",
        ]
        Resource = "arn:aws:ssm:*:*:session/$${aws:username}-*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:DescribeSessions",
          "ssm:GetConnectionStatus",
          "ssm:DescribeInstanceInformation",
          "ssm:DescribeInstanceProperties",
          "ec2:DescribeInstances",
        ]
        Resource = "*"
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# IAM Users (created per team_members variable)
# -----------------------------------------------------------------------------
resource "aws_iam_user" "team_member" {
  for_each = var.team_members

  name          = each.key
  force_destroy = true

  tags = {
    Name = each.key
  }
}

resource "aws_iam_user_group_membership" "team_member" {
  for_each = var.team_members

  user   = aws_iam_user.team_member[each.key].name
  groups = [for g in each.value.groups : "${var.project_name}-${g}-team"]

  depends_on = [
    aws_iam_group.cloud_team,
    aws_iam_group.be_team,
    aws_iam_group.fe_team,
    aws_iam_group.ai_team,
  ]
}

# -----------------------------------------------------------------------------
# Budget Alert
# -----------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project_name}-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.budget_limit_amount
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }
}
