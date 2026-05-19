resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  # dev 로그 — 짧게 보관 (비용 절감)
  rule {
    id     = "loki-dev-lifecycle"
    status = "Enabled"

    filter {
      prefix = "dev/"
    }

    expiration {
      days = 30
    }
  }

  # prod 로그 — 장기 보관
  rule {
    id     = "loki-prod-lifecycle"
    status = "Enabled"

    filter {
      prefix = "prod/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 90
    }
  }
}
