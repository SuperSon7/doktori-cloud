# -----------------------------------------------------------------------------
# AWS Data Source — ALB DNS 직접 조회 (terraform_remote_state 제거)
# -----------------------------------------------------------------------------
data "aws_lb" "frontend" {
  name = "${var.project_name}-${var.environment}-fe-alb"
}

locals {
  # nginx EC2 제거 후에는 ALB DNS를 직접 SSR origin으로 사용
  # 전환 전: var.ssr_origin_domain (origin.doktori.kr → nginx EIP)
  # 전환 후: ALB DNS (자동 참조)
  ssr_origin = var.ssr_origin_domain != "" ? var.ssr_origin_domain : data.aws_lb.frontend.dns_name
}

resource "aws_s3_bucket" "static" {
  bucket = var.static_bucket_name
}

resource "aws_s3_bucket_public_access_block" "static" {
  bucket                  = aws_s3_bucket.static.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${var.project_name}-${var.environment}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

resource "aws_cloudfront_cache_policy" "static_long" {
  name        = "${var.project_name}-${var.environment}-static-long"
  default_ttl = 60 * 60 * 24 * 30
  max_ttl     = 60 * 60 * 24 * 365
  min_ttl     = 60 * 60 * 24

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true

    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_origin_request_policy" "none" {
  name = "${var.project_name}-${var.environment}-origin-none"

  cookies_config {
    cookie_behavior = "none"
  }

  headers_config {
    header_behavior = "none"
  }

  query_strings_config {
    query_string_behavior = "none"
  }
}

resource "aws_cloudfront_origin_request_policy" "ssr_req" {
  name = "${var.project_name}-${var.environment}-origin-ssr"

  cookies_config {
    cookie_behavior = "all"
  }

  query_strings_config {
    query_string_behavior = "all"
  }

  headers_config {
    header_behavior = "whitelist"

    headers {
      items = ["Host", "Origin", "Referer", "Accept", "Accept-Language", "User-Agent"]
    }
  }
}

# -----------------------------------------------------------------------------
# Response Headers Policy — Security headers (기존 nginx에서 담당하던 역할)
#
# HSTS: 브라우저에게 HTTPS만 사용하도록 강제 (MITM 방지)
# X-Frame-Options: 클릭재킹 공격 방지 (iframe 삽입 차단)
# X-Content-Type-Options: MIME 스니핑 방지 (브라우저가 Content-Type 무시하고 추론하는 것 차단)
# Referrer-Policy: 외부 사이트로 이동 시 원본 URL 노출 범위 제한
# X-XSS-Protection: 레거시 브라우저의 XSS 필터 활성화
# -----------------------------------------------------------------------------
resource "aws_cloudfront_response_headers_policy" "security" {
  name = "${var.project_name}-${var.environment}-security-headers"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = false
      override                   = true
    }

    frame_options {
      frame_option = "SAMEORIGIN"
      override     = true
    }

    content_type_options {
      override = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }
  }
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.project_name}-${var.environment} static+ssr"
  aliases         = var.aliases

  origin {
    domain_name              = aws_s3_bucket.static.bucket_regional_domain_name
    origin_id                = "origin-static-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  origin {
    domain_name = local.ssr_origin
    origin_id   = "origin-next-app"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = var.ssr_origin_protocol_policy
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "origin-next-app"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
    cached_methods         = ["GET", "HEAD", "OPTIONS"]

    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id   = aws_cloudfront_origin_request_policy.ssr_req.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
    compress                   = true
  }

  ordered_cache_behavior {
    path_pattern           = "/_next/static/*"
    target_origin_id       = "origin-static-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD", "OPTIONS"]

    cache_policy_id            = aws_cloudfront_cache_policy.static_long.id
    origin_request_policy_id   = aws_cloudfront_origin_request_policy.none.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
    compress                   = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.acm_cert_arn == null
    acm_certificate_arn            = var.acm_cert_arn
    ssl_support_method             = var.acm_cert_arn == null ? null : "sni-only"
    minimum_protocol_version       = "TLSv1.2_2021"
  }
}

# -----------------------------------------------------------------------------
# GitHub Actions Deploy Role — CDN 배포 권한 (리소스 생성 후 attachment)
# role 자체는 global 레이어에서 생성, 리소스 종속 policy는 여기서 관리
# -----------------------------------------------------------------------------
data "aws_iam_role" "gha_deploy" {
  name = "${var.project_name}-gha-deploy"
}

resource "aws_iam_role_policy" "gha_cdn" {
  name = "${var.project_name}-gha-fe-cdn-prod"
  role = data.aws_iam_role.gha_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3BucketMeta"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.static.arn]
      },
      {
        Sid      = "S3ObjectWriteDelete"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.static.arn}/*"]
      },
      {
        Sid      = "CloudFrontInvalidation"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = [aws_cloudfront_distribution.cdn.arn]
      },
    ]
  })
}

data "aws_iam_policy_document" "static_bucket_policy" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.static.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cdn.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "static" {
  bucket = aws_s3_bucket.static.id
  policy = data.aws_iam_policy_document.static_bucket_policy.json
}

# -----------------------------------------------------------------------------
# ACM Certificate — CloudFront용 (us-east-1 필수)
# zone entity: dns-zone 레이어 / cert + validation record: 리소스(CloudFront)가 있는 이 레이어에서 관리
# -----------------------------------------------------------------------------
data "aws_route53_zone" "public" {
  name = var.domain_name
}

resource "aws_acm_certificate" "cdn" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cdn_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cdn.domain_validation_options : dvo.domain_name => {
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
}

resource "aws_acm_certificate_validation" "cdn" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cdn.arn
  validation_record_fqdns = [for r in aws_route53_record.cdn_cert_validation : r.fqdn]
}

# Public DNS — doktori.kr / www.doktori.kr → CloudFront
resource "aws_route53_record" "root" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}
