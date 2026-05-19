# --- ACM Certificate for api.doktori.kr ---
resource "aws_acm_certificate" "api" {
  domain_name       = "api.${var.domain_name}"
  validation_method = "DNS"

  tags = { Name = "${var.project_name}-${var.environment}-api-cert" }

  lifecycle {
    create_before_destroy = true
  }
}

# --- ACM Certificate for front.doktori.kr (ap-northeast-2) ---
# CloudFront → ALB https-only 연결을 위한 인증서
# CloudFront는 origin 도메인(front.doktori.kr)으로 TLS 핸드셰이크 → ALB가 이 인증서로 응답
resource "aws_acm_certificate" "alb_front" {
  domain_name       = "front.${var.domain_name}"
  validation_method = "DNS"

  tags = { Name = "${var.project_name}-${var.environment}-alb-front-cert" }

  lifecycle {
    create_before_destroy = true
  }
}
