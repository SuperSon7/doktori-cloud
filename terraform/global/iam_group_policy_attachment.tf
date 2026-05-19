resource "aws_iam_group_policy_attachment" "cloud_team_admin" {
  group      = aws_iam_group.cloud_team.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_group_policy_attachment" "cloud_team_billing" {
  group      = aws_iam_group.cloud_team.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBillingConductorFullAccess"
}
