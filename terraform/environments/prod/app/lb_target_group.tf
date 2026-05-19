# =============================================================================
# Public ALB Routing — path-based 규칙
#   /api/*   → K8s Worker NodePort (30080) → NGF → api/chat 분기
#   /ws/*    → K8s Worker NodePort (30080) → NGF (WebSocket)
#   /* (default) → Frontend ASG (port 3000)
# =============================================================================

# --- K8s Backend Target Group (Worker NodePort 30080) ---
resource "aws_lb_target_group" "k8s_backend" {
  name     = "${var.project_name}-${var.environment}-k8s-app-tg"
  port     = 30080
  protocol = "HTTP"
  vpc_id   = local.net.vpc_id

  health_check {
    path                = "/"
    port                = "30080"
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-404"
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-k8s-app-tg"
    Service = "k8s-worker"
  }

  lifecycle {
    create_before_destroy = true
  }
}
