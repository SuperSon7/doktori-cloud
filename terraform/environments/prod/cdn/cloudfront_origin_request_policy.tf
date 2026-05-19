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
