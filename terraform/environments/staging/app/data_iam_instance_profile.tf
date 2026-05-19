data "aws_iam_instance_profile" "staging_ec2_ssm" {
  name = "${var.project_name}-${var.environment}-ec2-ssm"
}
