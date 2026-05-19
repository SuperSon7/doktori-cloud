# -----------------------------------------------------------------------------
# SSM IAM Groups & Policies
# -----------------------------------------------------------------------------

# Cloud team - AdministratorAccess + Billing + SSM (Admin 그룹 통합)
resource "aws_iam_group" "cloud_team" {
  name = "${var.project_name}-cloud-team"
}

# BE team - api, chat, db in dev only
resource "aws_iam_group" "be_team" {
  name = "${var.project_name}-be-team"
}

# FE team - front in dev only
resource "aws_iam_group" "fe_team" {
  name = "${var.project_name}-fe-team"
}

# AI team - ai in dev only
resource "aws_iam_group" "ai_team" {
  name = "${var.project_name}-ai-team"
}
