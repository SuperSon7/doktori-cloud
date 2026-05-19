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

    # Keep CloudFront explicit in the timeout chain:
    # CloudFront is for the site origin. Long API/SSE/WS traffic should use api.doktori.kr directly.
    connection_attempts = 3
    connection_timeout  = 10

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_keepalive_timeout = 60
      origin_protocol_policy   = var.ssr_origin_protocol_policy
      origin_read_timeout      = 60
      origin_ssl_protocols     = ["TLSv1.2"]
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
