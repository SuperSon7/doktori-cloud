resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${local.name_prefix}-ec2-ssm"
  role = aws_iam_role.ec2_ssm.name
}
