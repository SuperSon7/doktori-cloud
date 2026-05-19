resource "aws_instance" "h_k8s" {
  for_each = local.h_k8s_nodes

  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = each.value.instance_type
  key_name               = null
  subnet_id              = aws_subnet.h_k8s[each.value.subnet_key].id
  vpc_security_group_ids = each.value.security_role == "master" ? [aws_security_group.h_k8s_master[0].id] : [aws_security_group.h_k8s_worker[0].id]
  iam_instance_profile   = data.aws_iam_instance_profile.staging_ec2_ssm.name

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = each.value.volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = each.key
    Service = each.value.role
  }

  depends_on = [aws_route_table_association.h_k8s]
}
