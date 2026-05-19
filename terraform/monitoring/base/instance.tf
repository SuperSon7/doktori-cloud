resource "aws_instance" "nat" {
  ami                    = data.aws_ami.nat_golden.id
  instance_type          = var.nat_instance_type
  key_name               = var.nat_key_name != "" ? var.nat_key_name : null
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false
  iam_instance_profile   = aws_iam_instance_profile.nat.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = "${var.project_name}-mgmt-nat-vpn"
    Service = "nat-vpn"
    Owner   = "cloud"
  }

  lifecycle {
    ignore_changes = []
  }

  depends_on = [aws_internet_gateway.mgmt]
}
