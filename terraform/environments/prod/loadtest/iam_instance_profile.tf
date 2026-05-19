resource "aws_iam_instance_profile" "k6_runner" {
  name = "${var.project_name}-${var.environment}-k6-runner"
  role = aws_iam_role.k6_runner.name
}
