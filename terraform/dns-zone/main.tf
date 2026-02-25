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
