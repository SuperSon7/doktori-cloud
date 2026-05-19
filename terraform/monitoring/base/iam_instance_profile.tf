resource "aws_iam_instance_profile" "nat" {
  name = "${var.project_name}-mgmt-nat-profile"
  role = aws_iam_role.nat.name
}
