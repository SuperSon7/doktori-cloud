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
