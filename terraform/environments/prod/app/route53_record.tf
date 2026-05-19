resource "aws_route53_record" "service" {
  for_each = local.compute_dns_name_map

  zone_id = local.net.internal_zone_id
  name    = "${each.value}.${local.net.internal_zone_name}"
  type    = "A"
  ttl     = 300
  records = [module.compute.private_ips[each.key]]
}

# =============================================================================
# DNS — ALB / NLB alias records
# =============================================================================

# Public App ALB → app-alb.prod.doktori.internal
resource "aws_route53_record" "app_alb" {
  zone_id = local.net.internal_zone_id
  name    = "app-alb.${local.net.internal_zone_name}"
  type    = "A"

  alias {
    name                   = module.frontend.alb_dns_name
    zone_id                = module.frontend.alb_zone_id
    evaluate_target_health = true
  }
}

# Backward-compatible alias for existing internal references.
resource "aws_route53_record" "frontend_alb" {
  zone_id = local.net.internal_zone_id
  name    = "front-alb.${local.net.internal_zone_name}"
  type    = "A"

  alias {
    name                   = module.frontend.alb_dns_name
    zone_id                = module.frontend.alb_zone_id
    evaluate_target_health = true
  }
}

# K8s Internal NLB → k8s.prod.doktori.internal
resource "aws_route53_record" "k8s_nlb" {
  zone_id = local.net.internal_zone_id
  name    = "k8s.${local.net.internal_zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [module.k8s_cluster.nlb_dns_name]
}

resource "aws_route53_record" "api_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.api.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.public.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]

  allow_overwrite = true
}

resource "aws_route53_record" "alb_front_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.alb_front.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.public.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]

  allow_overwrite = true
}

# Public DNS: front.doktori.kr → ALB
# CDN이 이 도메인을 origin으로 사용. 직접 접근 시 CloudFront 우회 가능하나
# SG 레벨 제어(CloudFront IP prefix list)는 추후 보안 강화 시 추가 예정
resource "aws_route53_record" "frontend_alb_public" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = "front.${var.domain_name}"
  type    = "A"

  alias {
    name                   = module.frontend.alb_dns_name
    zone_id                = module.frontend.alb_zone_id
    evaluate_target_health = true
  }
}

# -----------------------------------------------------------------------------
# Public DNS — api.doktori.kr → ALB
# zone entity: dns-zone 레이어 / record: 리소스(ALB)가 있는 이 레이어에서 관리
# -----------------------------------------------------------------------------
resource "aws_route53_record" "api_public" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  alias {
    name                   = module.frontend.alb_dns_name
    zone_id                = module.frontend.alb_zone_id
    evaluate_target_health = true
  }
}
