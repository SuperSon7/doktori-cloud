# ALB HTTPS listener에 front 인증서 추가 (SNI 기반 선택)
# CloudFront가 front.doktori.kr로 TLS 연결 시 이 인증서로 핸드셰이크
resource "aws_lb_listener_certificate" "alb_front" {
  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = aws_acm_certificate_validation.alb_front.certificate_arn
}
