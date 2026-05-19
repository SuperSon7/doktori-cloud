resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for r in aws_route53_record.api_cert_validation : r.fqdn]
}

resource "aws_acm_certificate_validation" "alb_front" {
  certificate_arn         = aws_acm_certificate.alb_front.arn
  validation_record_fqdns = [for r in aws_route53_record.alb_front_cert_validation : r.fqdn]
}
