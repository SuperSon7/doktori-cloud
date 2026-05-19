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
