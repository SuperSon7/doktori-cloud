resource "aws_iam_instance_profile" "nat" {
  count = var.nat_iam_instance_profile == "" ? 1 : 0

  name = "${var.project_name}-${var.environment}-nat-profile"
  role = aws_iam_role.nat[0].name
}
