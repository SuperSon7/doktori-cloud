resource "aws_instance" "runner" {
  for_each = local.runners

  ami                         = data.aws_ami.ubuntu_arm64.id
  instance_type               = var.instance_type
  subnet_id                   = each.value.subnet_id
  iam_instance_profile        = aws_iam_instance_profile.k6_runner.name
  vpc_security_group_ids      = [aws_security_group.k6_runner.id]
  associate_public_ip_address = true

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

  tags = {
    Name    = each.key
    Project = var.project_name
  }

  lifecycle {
    ignore_changes = [ami]
  }

  depends_on = [aws_iam_role_policy_attachment.ssm_managed]
}
