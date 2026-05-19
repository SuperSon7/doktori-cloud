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

resource "aws_route53_record" "rds_proxy" {
  zone_id = local.net.internal_zone_id
  name    = "db-proxy.${local.net.internal_zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [module.database.proxy_host]
}

resource "aws_route53_record" "data_service" {
  for_each = local.data_dns_name_map

  zone_id = local.net.internal_zone_id
  name    = "${each.value}.${local.net.internal_zone_name}"
  type    = "A"
  ttl     = 60
  records = [module.data_compute.private_ips[each.key]]
}

resource "aws_route53_record" "redis" {
  zone_id = local.net.internal_zone_id
  name    = "redis.${local.net.internal_zone_name}"
  type    = "CNAME"
  ttl     = 60
  records = ["redis-a.${local.net.internal_zone_name}"]
}

resource "aws_route53_record" "redis_sentinel" {
  count = var.enable_data_ha ? 1 : 0

  zone_id = local.net.internal_zone_id
  name    = "redis-sentinel.${local.net.internal_zone_name}"
  type    = "A"
  ttl     = 60
  records = [for key in local.redis_service_keys : module.data_compute.private_ips[key]]
}

resource "aws_route53_record" "rabbitmq" {
  zone_id = local.net.internal_zone_id
  name    = "rabbitmq.${local.net.internal_zone_name}"
  type    = "A"
  ttl     = 60
  records = [for key in local.rabbitmq_service_keys : module.data_compute.private_ips[key]]
}
