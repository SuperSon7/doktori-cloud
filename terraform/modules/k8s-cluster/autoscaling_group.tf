# -----------------------------------------------------------------------------
# Auto Scaling Groups
# -----------------------------------------------------------------------------
resource "aws_autoscaling_group" "master" {
  name                = "${var.project_name}-${var.environment}-k8s-master-asg"
  desired_capacity    = var.master_desired
  min_size            = var.master_desired
  max_size            = var.master_desired
  vpc_zone_identifier = var.private_subnet_ids

  target_group_arns         = [aws_lb_target_group.master_api.arn]
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.master.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}-k8s-master"
    propagate_at_launch = true
  }

  tag {
    key                 = "Service"
    value               = "k8s-cp"
    propagate_at_launch = true
  }

  tag {
    key                 = "Owner"
    value               = "cloud"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_group" "worker" {
  name                = "${var.project_name}-${var.environment}-k8s-worker-asg"
  desired_capacity    = var.worker_desired
  min_size            = var.worker_min
  max_size            = var.worker_max
  vpc_zone_identifier = var.private_subnet_ids

  health_check_type         = "EC2"
  health_check_grace_period = 300

  # 외부에서 aws_autoscaling_attachment로 TG를 추가 연결하므로
  # 모듈이 target_group_arns를 덮어쓰지 않도록 ignore
  lifecycle {
    ignore_changes = [target_group_arns]
  }

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}-k8s-worker"
    propagate_at_launch = true
  }

  tag {
    key                 = "Service"
    value               = "k8s-worker"
    propagate_at_launch = true
  }

  tag {
    key                 = "Owner"
    value               = "cloud"
    propagate_at_launch = true
  }
}
