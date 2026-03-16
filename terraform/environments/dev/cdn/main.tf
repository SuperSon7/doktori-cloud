data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.environment}/base/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_s3_bucket" "static" {
  bucket = data.terraform_remote_state.base.outputs.storage.bucket_names["app"]
}

locals {
  aliases         = [var.dev_domain_name]
  certificate_arn = var.create_acm_certificate ? aws_acm_certificate.dev[0].arn : var.acm_cert_arn
}

resource "aws_acm_certificate" "dev" {
  count = var.create_acm_certificate ? 1 : 0

  provider                  = aws.us_east_1
  domain_name               = var.dev_domain_name
  validation_method         = "DNS"
  subject_alternative_names = []

  lifecycle {
    create_before_destroy = true
  }
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

resource "aws_cloudfront_cache_policy" "next_image" {
  name        = "${var.project_name}-${var.environment}-next-image"
  default_ttl = var.next_image_default_ttl
  max_ttl     = var.next_image_max_ttl
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true

    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "whitelist"

      headers {
        items = ["Accept"]
      }
    }

    query_strings_config {
      query_string_behavior = "whitelist"

      query_strings {
        items = ["q", "url", "w"]
      }
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

resource "aws_cloudfront_origin_request_policy" "next_image" {
  name = "${var.project_name}-${var.environment}-origin-next-image"

  cookies_config {
    cookie_behavior = "none"
  }

  query_strings_config {
    query_string_behavior = "whitelist"

    query_strings {
      items = ["q", "url", "w"]
    }
  }

  headers_config {
    header_behavior = "whitelist"

    headers {
      items = ["Accept", "Host"]
    }
  }
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.project_name}-${var.environment} image-cache"
  aliases         = local.aliases

  lifecycle {
    precondition {
      condition     = local.certificate_arn != null
      error_message = "Provide a us-east-1 ACM certificate ARN or set create_acm_certificate=true before creating the dev CloudFront distribution."
    }
  }

  origin {
    domain_name = data.aws_s3_bucket.static.bucket_regional_domain_name
    origin_id   = "origin-static-s3"

    s3_origin_config {
      origin_access_identity = ""
    }
  }

  origin {
    domain_name = var.ssr_origin_domain
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

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.ssr_req.id
    compress                 = true
  }

  ordered_cache_behavior {
    path_pattern           = "/_next/image*"
    target_origin_id       = "origin-next-app"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD", "OPTIONS"]

    cache_policy_id          = aws_cloudfront_cache_policy.next_image.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.next_image.id
    compress                 = true
  }

  ordered_cache_behavior {
    path_pattern           = "/_next/static/*"
    target_origin_id       = "origin-static-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD", "OPTIONS"]

    cache_policy_id          = aws_cloudfront_cache_policy.static_long.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.none.id
    compress                 = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = local.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}
