# -----------------------------------------------------------------------------
# Launch Template + ASG
# -----------------------------------------------------------------------------
resource "aws_launch_template" "this" {
  name_prefix   = "${var.project_name}-${var.environment}-frontend-"
  image_id      = local.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name != "" ? var.key_name : null

  vpc_security_group_ids = concat(
    [aws_security_group.instance.id],
    var.extra_sg_ids,
  )

  iam_instance_profile {
    name = var.iam_instance_profile_name
  }

  user_data = var.user_data != "" ? base64encode(var.user_data) : null

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = var.volume_size
      volume_type = "gp3"
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project_name}-${var.environment}-frontend"
      Service = "front"
      Owner   = "fe"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
