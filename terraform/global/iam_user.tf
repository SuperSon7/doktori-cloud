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
