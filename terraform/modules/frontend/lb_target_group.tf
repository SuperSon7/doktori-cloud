resource "aws_lb_target_group" "this" {
  name                 = "${var.project_name}-${var.environment}-front-tg"
  port                 = var.app_port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  deregistration_delay = 300

  health_check {
    path                = var.health_check_path
    port                = tostring(var.app_port)
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-front-tg"
    Service = "front"
  }

  lifecycle {
    create_before_destroy = true
  }
}
