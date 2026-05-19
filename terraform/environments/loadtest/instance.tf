resource "aws_instance" "runner" {
  count = var.runner_count

  ami                    = var.runner_ami_id != "" ? var.runner_ami_id : data.aws_ami.ubuntu_arm64.id
  instance_type          = var.instance_type
  key_name               = "doktori-loadtest"
  subnet_id              = aws_subnet.public[count.index % length(aws_subnet.public)].id
  iam_instance_profile   = aws_iam_instance_profile.k6_runner.name
  vpc_security_group_ids = [aws_security_group.k6_runner.id]

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = base64encode(
    count.index == 0
    ? file("${path.module}/scripts/user-data-monitoring.sh")
    : file("${path.module}/scripts/user-data-runner.sh")
  )

  tags = {
    Name   = "${var.project_name}-k6-runner-${count.index + 1}"
    Access = "ssm-only"
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm_managed,
    aws_route.public_internet,
  ]
}
