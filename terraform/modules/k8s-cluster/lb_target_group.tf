# --- Control-plane target group + listener (kubeadm HA endpoint) ---
resource "aws_lb_target_group" "master_api" {
  name        = "${var.project_name}-${var.environment}-k8s-api-tg"
  port        = 6443
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = "6443"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-k8s-api-tg"
    Service = "k8s-cp"
  }
}
