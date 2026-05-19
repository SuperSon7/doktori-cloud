# -----------------------------------------------------------------------------
# Route53 — RDS internal CNAME
# -----------------------------------------------------------------------------
resource "aws_route53_record" "rds" {
  zone_id = local.net.internal_zone_id
  name    = "db.${local.net.internal_zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [module.database.db_host]
}
