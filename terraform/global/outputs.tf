output "github_actions_role_arn" {
  description = "GitHub Actions deploy role ARN"
  value       = aws_iam_role.github_actions_deploy.arn
}

output "cloud_team_group_name" {
  description = "Cloud team IAM group name"
  value       = aws_iam_group.cloud_team.name
}

output "be_team_group_name" {
  description = "BE team IAM group name"
  value       = aws_iam_group.be_team.name
}

output "fe_team_group_name" {
  description = "FE team IAM group name"
  value       = aws_iam_group.fe_team.name
}

output "ai_team_group_name" {
  description = "AI team IAM group name"
  value       = aws_iam_group.ai_team.name
}
