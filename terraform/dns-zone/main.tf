variable "project_name" {
  description = "Project name"
  type        = string
  default     = "doktori"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "domain_name" {
  description = "Root domain name"
  type        = string
  default     = "doktori.kr"
}

variable "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  type        = string
}

variable "cloudfront_hosted_zone_id" {
  description = "CloudFront hosted zone ID (always Z2FDTNDATAQYW2)"
  type        = string
  default     = "Z2FDTNDATAQYW2"
}

variable "alb_dns_name" {
  description = "Public ALB DNS name for api subdomain"
  type        = string
}

variable "alb_zone_id" {
  description = "Public ALB hosted zone ID"
  type        = string
}

variable "acm_validation_records" {
  description = "ACM certificate DNS validation records"
  type = map(object({
    name  = string
    type  = string
    value = string
  }))
  default = {}
}

# -----------------------------------------------------------------------------
# Route53 Hosted Zone
# -----------------------------------------------------------------------------
resource "aws_route53_zone" "main" {
  name = var.domain_name

  tags = {
    Name = var.domain_name
  }
}

# -----------------------------------------------------------------------------
# Common DNS Records (MX, TXT, DKIM for Google Workspace)
# -----------------------------------------------------------------------------
resource "aws_route53_record" "mx" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "MX"
  ttl     = 300
  records = ["1 SMTP.GOOGLE.COM"]
}

resource "aws_route53_record" "txt" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "TXT"
  ttl     = 3600
  records = ["google-site-verification=9ThKMf-NgIt_TbmipWbEf7weA74fNhOPlPTT1SsvnAI"]
}

resource "aws_route53_record" "dkim" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "google._domainkey.${var.domain_name}"
  type    = "TXT"
  ttl     = 300
  records = ["v=DKIM1;k=rsa;p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCRFYrAcT+nKoNyHyuKL1aEJayaqFFzDdPmvlgU2fHu7MVe+c75QkR/+a2Tes9y/5Juipp2KRWnC7xKdPuZAWVHQPd/oGIBPeA6mOWeoI/dlmTgEj5jQQkep9ZHNpLZwP1CnR03+O8TmS4DjicwkLUQ5tvKmN2WEL+dl3b79wTiQQIDAQAB"]
}

# -----------------------------------------------------------------------------
# CloudFront Alias Records
# -----------------------------------------------------------------------------
resource "aws_route53_record" "root" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = var.cloudfront_domain_name
    zone_id                = var.cloudfront_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.cloudfront_domain_name
    zone_id                = var.cloudfront_hosted_zone_id
    evaluate_target_health = false
  }
}

# -----------------------------------------------------------------------------
# API subdomain → ALB (bypass CloudFront for API traffic)
# -----------------------------------------------------------------------------
resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# -----------------------------------------------------------------------------
# Legacy records (migrated from old account)
# -----------------------------------------------------------------------------
resource "aws_route53_record" "dev" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "dev.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = ["10.0.28.175"]
}

resource "aws_route53_record" "monitoring" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "monitoring.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = ["3.37.104.151"]
}

resource "aws_route53_record" "origin" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "origin.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = ["3.34.245.126"]
}

# -----------------------------------------------------------------------------
# ACM Certificate Validation (CloudFront cert)
# -----------------------------------------------------------------------------
resource "aws_route53_record" "acm_validation" {
  for_each = var.acm_validation_records

  zone_id = aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.value]
}
