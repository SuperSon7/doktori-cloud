# -----------------------------------------------------------------------------
# PHZ Record — monitoring.mgmt.doktori.internal
# -----------------------------------------------------------------------------
resource "aws_route53_record" "monitoring" {
  zone_id = data.aws_route53_zone.mgmt.zone_id
  name    = "monitoring.${data.aws_route53_zone.mgmt.name}"
  type    = "A"
  ttl     = 300
  records = [aws_instance.monitoring.private_ip]
}
