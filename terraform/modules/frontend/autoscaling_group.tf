resource "aws_autoscaling_group" "this" {
  name                = "${var.project_name}-${var.environment}-frontend-asg"
  desired_capacity    = var.desired_capacity
  min_size            = var.min_size
  max_size            = var.max_size
  vpc_zone_identifier = var.private_subnet_ids

  target_group_arns         = [aws_lb_target_group.this.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}-frontend"
    propagate_at_launch = true
  }

  tag {
    key                 = "Service"
    value               = "front"
    propagate_at_launch = true
  }

  tag {
    key                 = "Owner"
    value               = "fe"
    propagate_at_launch = true
  }
}
