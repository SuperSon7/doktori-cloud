resource "aws_instance" "nat" {
  for_each = local.nat_instances

  ami                         = var.nat_ami_id
  instance_type               = var.nat_instance_type
  key_name                    = var.nat_key_name != "" ? var.nat_key_name : null
  subnet_id                   = aws_subnet.this[each.value.subnet_key].id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.nat.id]
  source_dest_check           = false
  iam_instance_profile        = local.nat_instance_profile

  user_data = trimspace(var.nat_user_data) != "" ? var.nat_user_data : null

  user_data_replace_on_change = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = var.nat_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(
    {
      Name    = "${var.project_name}-${var.environment}-nat-${each.key}"
      Service = "nat"
    },
    var.nat_extra_tags,
  )

  lifecycle {
    # NAT는 golden AMI와 optional user_data drift가 plan에서 보이도록 유지한다.
    ignore_changes = []
  }

  depends_on = [aws_internet_gateway.main]
}
