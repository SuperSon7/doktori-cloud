# -----------------------------------------------------------------------------
# Current AWS Account (하드코딩 방지)
# -----------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Remote State: Compute (for app security group ID)
# -----------------------------------------------------------------------------
data "terraform_remote_state" "compute" {
  backend = "s3"
  config = {
    bucket = "doktori-v2-terraform-state"
    key    = "compute/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# -----------------------------------------------------------------------------
# GitHub OIDC Provider
# -----------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name = "github-actions-oidc"
  }
}

# -----------------------------------------------------------------------------
# GitHub Actions Deploy Role (OIDC)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "github_actions_deploy" {
  name        = "GitHubActions-Deploy-Role"
  description = "Doktori-GHA-Deploy-Role"

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
            "token.actions.githubusercontent.com:sub" = [
              "repo:100-hours-a-week/5-team-service-be:ref/refs/heads/main",
              "repo:100-hours-a-week/5-team-service-be:ref/refs/heads/develop",
              "repo:100-hours-a-week/5-team-service-fe:ref/refs/heads/main",
              "repo:100-hours-a-week/5-team-service-fe:ref/refs/heads/develop",
              "repo:100-hours-a-week/5-team-service-ai:ref/refs/heads/main",
              "repo:100-hours-a-week/5-team-service-ai:ref/refs/heads/develop",
            ]
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name = "GitHubActions-Deploy-Role"
  }
}

# -----------------------------------------------------------------------------
# GitHub Actions IAM User
# -----------------------------------------------------------------------------
resource "aws_iam_user" "github_action" {
  name = "${var.project_name}-github-action"

  tags = {
    Name = "${var.project_name}-github-action"
  }
}

resource "aws_iam_policy" "dev_github_actions" {
  name        = "${var.project_name}-dev-github-actions"
  description = "doktori dev github actions aws 22 port"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress"
        ]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group/${data.terraform_remote_state.compute.outputs.security_group_id}"
        ]
      }
    ]
  })
}

resource "aws_iam_policy" "prod_github_actions" {
  name        = "${var.project_name}-prod-github-actions"
  description = "prod github actions"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lightsail:OpenInstancePublicPorts",
          "lightsail:CloseInstancePublicPorts",
          "lightsail:GetInstance",
          "lightsail:GetInstancePortStates"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "github_action_dev" {
  user       = aws_iam_user.github_action.name
  policy_arn = aws_iam_policy.dev_github_actions.arn
}

resource "aws_iam_user_policy_attachment" "github_action_prod" {
  user       = aws_iam_user.github_action.name
  policy_arn = aws_iam_policy.prod_github_actions.arn
}

# -----------------------------------------------------------------------------
# Prod Lightsail IAM User
# -----------------------------------------------------------------------------
resource "aws_iam_user" "prod_lightsail" {
  name = "${var.project_name}-prod-lightsail"

  tags = {
    Name = "${var.project_name}-prod-lightsail"
  }
}

resource "aws_iam_user_policy" "prod_lightsail_s3" {
  name = "${var.project_name}-prod-lightsail-s3"
  user = aws_iam_user.prod_lightsail.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.project_name}-prod-images/*",
          "arn:aws:s3:::${var.project_name}-prod-db-backup/*",
          "arn:aws:s3:::${var.project_name}-prod-backend-log-backup",
          "arn:aws:s3:::${var.project_name}-prod-backend-log-backup/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.project_name}-prod-images",
          "arn:aws:s3:::${var.project_name}-prod-db-backup",
          "arn:aws:s3:::${var.project_name}-prod-backend-log-backup",
          "arn:aws:s3:::${var.project_name}-prod-backend-log-backup/*"
        ]
      }
    ]
  })
}

resource "aws_iam_policy" "prod_parameter_store_read" {
  name        = "${var.project_name}-prod-parameter-store-read"
  description = "Policy to read Parameter Store secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/prod/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = "arn:aws:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:key/*"
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "prod_lightsail_parameter_store" {
  user       = aws_iam_user.prod_lightsail.name
  policy_arn = aws_iam_policy.prod_parameter_store_read.arn
}

# -----------------------------------------------------------------------------
# Prod S3 Developer IAM User
# -----------------------------------------------------------------------------
resource "aws_iam_user" "prod_s3_developer" {
  name = "${var.project_name}-prod-s3-developer"

  tags = {
    Name = "${var.project_name}-prod-s3-developer"
  }
}

resource "aws_iam_user_policy" "prod_s3_developer" {
  name = "${var.project_name}-prod-s3-developer"
  user = aws_iam_user.prod_s3_developer.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "arn:aws:s3:::${var.project_name}-prod-images/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = "arn:aws:s3:::${var.project_name}-prod-images"
      }
    ]
  })
}
