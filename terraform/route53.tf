# -----------------------------------------------------------------------------
# Route53 Hosted Zone
# -----------------------------------------------------------------------------
resource "aws_route53_zone" "main" {
  name = "doktori.kr"

  tags = {
    Name = "doktori.kr"
  }
}

# -----------------------------------------------------------------------------
# DNS Records
# -----------------------------------------------------------------------------

# Root domain → Lightsail prod (3.37.180.158)
resource "aws_route53_record" "root_a" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "doktori.kr"
  type    = "A"
  ttl     = 300
  records = ["3.37.180.158"]
}

# www → Lightsail prod
resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "www.doktori.kr"
  type    = "A"
  ttl     = 300
  records = ["3.37.180.158"]
}

# dev → EC2 dev app
resource "aws_route53_record" "dev" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "dev.doktori.kr"
  type    = "A"
  ttl     = 300
  records = ["52.79.205.195"]
}

# monitoring → Monitoring EC2
resource "aws_route53_record" "monitoring" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "monitoring.doktori.kr"
  type    = "A"
  ttl     = 300
  records = ["3.36.172.142"]
}

# MX record for Google Workspace
resource "aws_route53_record" "mx" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "doktori.kr"
  type    = "MX"
  ttl     = 300
  records = ["1 SMTP.GOOGLE.COM"]
}

# TXT record - Google site verification
resource "aws_route53_record" "txt" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "doktori.kr"
  type    = "TXT"
  ttl     = 3600
  records = ["google-site-verification=9ThKMf-NgIt_TbmipWbEf7weA74fNhOPlPTT1SsvnAI"]
}

# DKIM record for Google Workspace
resource "aws_route53_record" "dkim" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "google._domainkey.doktori.kr"
  type    = "TXT"
  ttl     = 300
  records = ["v=DKIM1;k=rsa;p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCRFYrAcT+nKoNyHyuKL1aEJayaqFFzDdPmvlgU2fHu7MVe+c75QkR/+a2Tes9y/5Juipp2KRWnC7xKdPuZAWVHQPd/oGIBPeA6mOWeoI/dlmTgEj5jQQkep9ZHNpLZwP1CnR03+O8TmS4DjicwkLUQ5tvKmN2WEL+dl3b79wTiQQIDAQAB"]
}