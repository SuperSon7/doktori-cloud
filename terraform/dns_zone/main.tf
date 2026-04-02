# -----------------------------------------------------------------------------
# Route53 Public Hosted Zone
# -----------------------------------------------------------------------------
resource "aws_route53_zone" "main" {
  name = var.domain_name

  tags = {
    Name = var.domain_name
  }

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# 정적 레코드 — Google Workspace (메일, 도메인 인증)
# 리소스에 종속되지 않으므로 dns-zone 레이어에서 관리
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
# 동적 레코드는 해당 리소스 레이어에서 관리 (PRINCIPLES.md §3)
#
# CloudFront alias (@, www)  → environments/prod/cdn/main.tf
# ALB alias (api.doktori.kr) → environments/prod/app/main.tf
# ACM validation records     → environments/prod/cdn/main.tf (CloudFront cert)
# dev/monitoring/origin A    → 각 환경 레이어에서 EIP 확정 후 추가
# -----------------------------------------------------------------------------
