resource "aws_iam_role_policy_attachment" "nat_ssm" {
  count = var.nat_iam_instance_profile == "" ? 1 : 0

  role       = aws_iam_role.nat[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
