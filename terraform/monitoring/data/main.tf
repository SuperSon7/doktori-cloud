# =============================================================================
# Monitoring Data — S3 저장소
# =============================================================================

# -----------------------------------------------------------------------------
# Loki — 로그 장기 저장소
# auth_enabled: true 기반 dev/prod prefix 분리
# prefix 구조: {bucket}/dev/chunks, {bucket}/prod/chunks
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "loki" {
  bucket = "${var.project_name}-monitoring-loki"

  tags = {
    Name    = "${var.project_name}-monitoring-loki"
    Service = "monitoring"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket = aws_s3_bucket.loki.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

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
