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
  # Deploy role: 모든 서비스 레포 + Cloud 레포 (main, develop, staging, feature/*)
  github_oidc_subjects = concat(
    flatten([
      for repo in var.github_repos : [
        "repo:${var.github_org}/${repo}:ref:refs/heads/main",
        "repo:${var.github_org}/${repo}:ref:refs/heads/develop",
        "repo:${var.github_org}/${repo}:ref:refs/heads/staging",
      ]
    ]),
    [
      "repo:${var.github_org}/${var.cloud_repo}:ref:refs/heads/feature/*",
      "repo:${var.github_org}/5-team-service-fe:ref:refs/heads/feature/s3-CDN",
    ],
  )

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

resource "aws_iam_role_policy" "github_actions_cdn" {
  count = var.static_bucket_name != null && var.cloudfront_distribution_id != null ? 1 : 0

  name = "${var.project_name}-gha-fe-cdn-prod"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketMeta"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = ["arn:${data.aws_partition.current.partition}:s3:::${var.static_bucket_name}"]
      },
      {
        Sid    = "S3ObjectWriteDelete"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = ["arn:${data.aws_partition.current.partition}:s3:::${var.static_bucket_name}/*"]
      },
      {
        Sid    = "CloudFrontInvalidation"
        Effect = "Allow"
        Action = [
          "cloudfront:CreateInvalidation",
        ]
        Resource = ["arn:${data.aws_partition.current.partition}:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/${var.cloudfront_distribution_id}"]
      },
    ]
  })
}

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
      {
        Sid    = "KMSDecryptParameterStore"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:Encrypt"]
        Resource = [
          "arn:aws:kms:ap-northeast-2:250857930609:key/2ddbf5d2-3960-4d7c-97cd-45e7cd7fa2e6",
          "arn:aws:kms:ap-northeast-2:250857930609:key/e30d6af4-88ef-420a-b1ef-9d43d1ef8010",
          "arn:aws:kms:ap-northeast-2:250857930609:key/709fb125-d24d-4365-a33d-ebbeb9a4ec39",
        ]
      },
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
      {
        Sid    = "TerraformStateLock"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
        ]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/*terraform*"
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

# -----------------------------------------------------------------------------
# Admin Group + Admin Users
# -----------------------------------------------------------------------------
resource "aws_iam_group" "admin" {
  name = "Admin"
}

resource "aws_iam_group_policy_attachment" "admin_access" {
  group      = aws_iam_group.admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_group_policy_attachment" "admin_billing" {
  group      = aws_iam_group.admin.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBillingConductorFullAccess"
}

resource "aws_iam_user" "admin" {
  for_each = var.admin_users

  name          = each.key
  force_destroy = true

  tags = {
    Name = each.key
  }
}

resource "aws_iam_user_group_membership" "admin" {
  for_each = var.admin_users

  user   = aws_iam_user.admin[each.key].name
  groups = [aws_iam_group.admin.name]
}

# -----------------------------------------------------------------------------
# Service Accounts
# -----------------------------------------------------------------------------
resource "aws_iam_user" "grafana_billing_reader" {
  name          = "grafana-billing-reader"
  force_destroy = true

  tags = {
    Name    = "grafana-billing-reader"
    Service = "monitoring"
  }
}

resource "aws_iam_user_policy_attachment" "grafana_cloudwatch" {
  user       = aws_iam_user.grafana_billing_reader.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
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
