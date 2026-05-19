resource "aws_lb_listener" "nlb_api" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.master_api.arn
  }
}
