# =============================================================================
# RDS Proxy
# =============================================================================

# -----------------------------------------------------------------------------
# Secrets Manager — Proxy가 RDS 인증에 사용
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "db_credentials" {
  count = var.enable_rds_proxy ? 1 : 0

  name        = "${var.project_name}-${var.environment}-db-credentials"
  description = "RDS credentials for RDS Proxy authentication"

  tags = {
    Name    = "${var.project_name}-${var.environment}-db-credentials"
    Service = "db"
  }
}
