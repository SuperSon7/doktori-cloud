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
