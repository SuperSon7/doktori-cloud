# -----------------------------------------------------------------------------
# Launch Templates
# -----------------------------------------------------------------------------
resource "aws_launch_template" "master" {
  name_prefix            = "${var.project_name}-${var.environment}-k8s-master-"
  image_id               = local.ami_id
  instance_type          = var.master_instance_type
  key_name               = var.key_name != "" ? var.key_name : null
  update_default_version = true

  vpc_security_group_ids = [aws_security_group.master.id]

  iam_instance_profile {
    name = var.iam_instance_profile_name
  }

  user_data = var.user_data_master != "" ? base64encode(var.user_data_master) : null

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2 # Pod에서 IMDS 접근 필요
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = var.master_volume_size
      volume_type = "gp3"
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project_name}-${var.environment}-k8s-master"
      Service = "k8s-cp"
      Owner   = "cloud"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_launch_template" "worker" {
  name_prefix            = "${var.project_name}-${var.environment}-k8s-worker-"
  image_id               = local.ami_id
  instance_type          = var.worker_instance_type
  key_name               = var.key_name != "" ? var.key_name : null
  update_default_version = true

  vpc_security_group_ids = [aws_security_group.worker.id]

  iam_instance_profile {
    name = var.iam_instance_profile_name
  }

  user_data = var.user_data_worker != "" ? base64encode(var.user_data_worker) : null

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2 # Pod에서 IMDS 접근 필요
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = var.worker_volume_size
      volume_type = "gp3"
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project_name}-${var.environment}-k8s-worker"
      Service = "k8s-worker"
      Owner   = "cloud"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
