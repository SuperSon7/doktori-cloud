# --- HTTP → HTTPS redirect for api.doktori.kr direct access ---
# CloudFront → ALB 트래픽은 Host: doktori.kr 이므로 영향 없음
resource "aws_lb_listener_rule" "api_http_redirect" {
  listener_arn = module.frontend.http_listener_arn
  priority     = 1

  action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  condition {
    host_header {
      values = ["api.${var.domain_name}"]
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- ALB Listener Rules (path-based routing) ---
# /api/* → K8s (NGF가 /api/chat/, /api/chat-rooms/, /api/ 분기)
resource "aws_lb_listener_rule" "api" {
  listener_arn = module.frontend.http_listener_arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8s_backend.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# /ws/* → K8s (WebSocket — /ws/chat 등)
resource "aws_lb_listener_rule" "ws" {
  listener_arn = module.frontend.http_listener_arn
  priority     = 110

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8s_backend.arn
  }

  condition {
    path_pattern {
      values = ["/ws/*"]
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# HTTPS listener rules (same as HTTP)
resource "aws_lb_listener_rule" "api_https" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8s_backend.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener_rule" "ws_https" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 110

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8s_backend.arn
  }

  condition {
    path_pattern {
      values = ["/ws/*"]
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
