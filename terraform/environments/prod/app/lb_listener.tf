# --- ALB HTTPS Listener ---
resource "aws_lb_listener" "https" {
  load_balancer_arn = module.frontend.alb_arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.api.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = module.frontend.target_group_arn
  }

  lifecycle {
    create_before_destroy = true
  }
}
