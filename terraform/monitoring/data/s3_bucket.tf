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
