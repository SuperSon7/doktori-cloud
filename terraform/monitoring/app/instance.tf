# -----------------------------------------------------------------------------
# EC2 Instance
# -----------------------------------------------------------------------------
resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = local.base.private_subnet_id
  vpc_security_group_ids = [aws_security_group.monitoring.id]
  iam_instance_profile   = aws_iam_instance_profile.monitoring.name

  user_data = templatefile("${path.module}/scripts/user_data.sh", {
    project_name = var.project_name
    architecture = var.architecture
  })

  metadata_options {
    http_tokens                 = "required" # IMDSv2 강제
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2 # Docker 컨테이너 → IMDS 접근 허용
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name    = "${var.project_name}-monitoring"
    Service = "monitoring"
    Owner   = "cloud"
  }

  lifecycle {
    # AMI ID는 most_recent로 매번 달라지므로 apply 시 재생성 방지
    ignore_changes = [ami]
  }
}
