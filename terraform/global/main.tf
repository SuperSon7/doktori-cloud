# -----------------------------------------------------------------------------
# GitHub OIDC Provider
# -----------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name = "${var.project_name}-github-actions-oidc"
  }
}

# -----------------------------------------------------------------------------
# SSM Service-Linked Role (태그 기반 타겟팅에 필요)
# -----------------------------------------------------------------------------
resource "aws_iam_service_linked_role" "ssm" {
  aws_service_name = "ssm.amazonaws.com"
}

resource "aws_iam_service_linked_role" "autoscaling" {
  aws_service_name = "autoscaling.amazonaws.com"
}


# -----------------------------------------------------------------------------
# GitHub Actions Deploy Role (OIDC)
# -----------------------------------------------------------------------------
locals {
  # Deploy role: 서비스 레포 전용 (be/fe/ai) — ECR push, SSM 배포 용도
  # Cloud 레포는 terraform_oidc_subjects(아래)에서 별도 관리
  github_oidc_subjects = flatten([
      for repo in var.github_repos : [
        "repo:${var.github_org}/${repo}:ref:refs/heads/main",
        "repo:${var.github_org}/${repo}:ref:refs/heads/develop",
        "repo:${var.github_org}/${repo}:ref:refs/heads/staging",
      ]
    ])


  # Terraform role: Cloud 레포 전용 (main, feature/*, PR)
  terraform_oidc_subjects = [
    "repo:${var.github_org}/${var.cloud_repo}:ref:refs/heads/main",
    "repo:${var.github_org}/${var.cloud_repo}:ref:refs/heads/feature/*",
    "repo:${var.github_org}/${var.cloud_repo}:pull_request",
  ]
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

# CDN 배포 권한(S3 write, CloudFront invalidation)은 prod/cdn 레이어에서 attachment
# 해당 리소스(S3 bucket, CloudFront distribution)가 생성된 후 ARN 참조 가능
# → terraform/environments/prod/cdn/main.tf 참조

# -----------------------------------------------------------------------------
# GitHub Actions Terraform Role (OIDC) — Cloud repo only
# -----------------------------------------------------------------------------
resource "aws_iam_role" "github_actions_terraform" {
  name        = "${var.project_name}-gha-terraform"
  description = "GitHub Actions Terraform plan/apply role (Cloud repo only)"

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
            "token.actions.githubusercontent.com:sub" = local.terraform_oidc_subjects
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-gha-terraform"
  }
}

resource "aws_iam_role_policy" "terraform_infra" {
  name = "${var.project_name}-terraform-permissions"
  role = aws_iam_role.github_actions_terraform.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EC2Full"
        Effect   = "Allow"
        Action   = ["ec2:*"]
        Resource = "*"
      },
      {
        Sid      = "RDS"
        Effect   = "Allow"
        Action   = ["rds:*"]
        Resource = "*"
      },
      {
        Sid      = "S3"
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = "*"
      },
      {
        Sid    = "IAM"
        Effect = "Allow"
        Action = [
          "iam:GetRole", "iam:GetPolicy", "iam:GetPolicyVersion",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:GetRolePolicy", "iam:GetInstanceProfile",
          "iam:ListInstanceProfilesForRole",
          "iam:CreateRole", "iam:DeleteRole",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
          "iam:PassRole", "iam:TagRole", "iam:UntagRole",
          "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
          "iam:CreatePolicy", "iam:DeletePolicy",
          "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
          "iam:ListPolicyVersions", "iam:UpdateAssumeRolePolicy",
          "iam:GetOpenIDConnectProvider", "iam:TagPolicy", "iam:UntagPolicy",
        ]
        Resource = "*"
      },
      {
        Sid    = "SSMParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter", "ssm:GetParameters",
          "ssm:PutParameter", "ssm:DeleteParameter",
          "ssm:DescribeParameters",
          "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource",
          "ssm:ListTagsForResource",
        ]
        Resource = "*"
      },
      {
        Sid    = "KMSManagement"
        Effect = "Allow"
        Action = [
          "kms:CreateKey", "kms:DescribeKey",
          "kms:GetKeyPolicy", "kms:GetKeyRotationStatus",
          "kms:ListResourceTags", "kms:CreateAlias", "kms:DeleteAlias",
          "kms:ListAliases", "kms:TagResource", "kms:UntagResource",
          "kms:EnableKeyRotation", "kms:ScheduleKeyDeletion",
        ]
        Resource = "*"
      },
      # KMS Decrypt: KMS 키 생성 레이어(base/data)에서 data "aws_kms_key"로 참조 후 별도 policy attachment
      # → 키가 존재하기 전에 ARN 하드코딩 금지 (PRINCIPLES.md §11)
      {
        Sid      = "ELB"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:*"]
        Resource = "*"
      },
      {
        Sid      = "AutoScaling"
        Effect   = "Allow"
        Action   = ["autoscaling:*"]
        Resource = "*"
      },
      {
        Sid      = "ECR"
        Effect   = "Allow"
        Action   = ["ecr:*"]
        Resource = "*"
      },
      {
        Sid      = "ACM"
        Effect   = "Allow"
        Action   = ["acm:*"]
        Resource = "*"
      },
      {
        Sid      = "Lambda"
        Effect   = "Allow"
        Action   = ["lambda:*"]
        Resource = "*"
      },
      {
        Sid      = "Scheduler"
        Effect   = "Allow"
        Action   = ["scheduler:*"]
        Resource = "*"
      },
      {
        Sid      = "Route53"
        Effect   = "Allow"
        Action   = ["route53:*"]
        Resource = "*"
      },
      {
        Sid      = "CloudWatch"
        Effect   = "Allow"
        Action   = ["cloudwatch:*", "logs:*"]
        Resource = "*"
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# SSM IAM Groups & Policies
# -----------------------------------------------------------------------------

# Cloud team - AdministratorAccess + Billing + SSM (Admin 그룹 통합)
resource "aws_iam_group" "cloud_team" {
  name = "${var.project_name}-cloud-team"
}

resource "aws_iam_group_policy_attachment" "cloud_team_admin" {
  group      = aws_iam_group.cloud_team.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_group_policy_attachment" "cloud_team_billing" {
  group      = aws_iam_group.cloud_team.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBillingConductorFullAccess"
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
            "ssm:resourceTag/Service"     = ["app"]
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
      {
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
          "ssm:DeleteParameter",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:DescribeParameters",
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

# Admin 그룹 제거 — cloud_team으로 통합 (AdministratorAccess + Billing 동일)

# Service Accounts (grafana-billing-reader)
# Grafana EC2 instance profile으로 대체 — terraform/monitoring/app/main.tf 참조
# IAM user + 장기 자격증명 방식 제거 (보안 개선)

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
