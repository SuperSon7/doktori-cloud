# -----------------------------------------------------------------------------
# EC2 Instances (for_each)
# -----------------------------------------------------------------------------
resource "aws_instance" "this" {
  for_each = var.services

  ami                    = each.value.ami_id != "" ? each.value.ami_id : local.default_ami[each.value.architecture]
  instance_type          = each.value.instance_type
  key_name               = var.key_name != "" ? var.key_name : null
  subnet_id              = var.subnet_ids[each.value.subnet_key]
  vpc_security_group_ids = [aws_security_group.this[each.key].id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  user_data              = each.value.user_data != "" ? each.value.user_data : null

  user_data_replace_on_change = false

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

  tags = merge(
    {
      Name    = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}"
      Service = each.key
    },
    each.value.tags,
  )

  lifecycle {
    # AMI/user_data drift must be visible. Data nodes and golden-image based
    # services rely on Terraform planning replacement when a Packer AMI changes.
    # Hiding these fields allowed Ubuntu fallback instances to persist even after
    # service-specific AMIs were configured.
    ignore_changes = []
  }
}
