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
