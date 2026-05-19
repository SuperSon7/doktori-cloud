# -----------------------------------------------------------------------------
# ALB
# -----------------------------------------------------------------------------
resource "aws_lb" "this" {
  name               = "${var.project_name}-${var.environment}-app-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  # WebSocket/SSE 연결 유지를 위해 3600초(1시간)로 설정
  # ALB 기본값은 60초 → WS idle 시 조기 끊김 발생
  idle_timeout = var.idle_timeout

  tags = {
    Name    = "${var.project_name}-${var.environment}-app-alb"
    Service = "app-alb"
  }

  lifecycle {
    create_before_destroy = true
  }
}
