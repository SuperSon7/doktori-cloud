# -----------------------------------------------------------------------------
# RDS Proxy 인스턴스
# -----------------------------------------------------------------------------
resource "aws_db_proxy" "main" {
  count = var.enable_rds_proxy ? 1 : 0

  name                   = "${var.project_name}-${var.environment}-proxy"
  engine_family          = "MYSQL"
  role_arn               = aws_iam_role.rds_proxy[0].arn
  vpc_subnet_ids         = var.db_subnet_ids
  vpc_security_group_ids = [aws_security_group.rds.id]

  auth {
    auth_scheme = "SECRETS"
    secret_arn  = aws_secretsmanager_secret.db_credentials[0].arn
    iam_auth    = "DISABLED"
  }

  idle_client_timeout = var.rds_proxy_idle_client_timeout
  require_tls         = false

  tags = {
    Name    = "${var.project_name}-${var.environment}-proxy"
    Service = "db"
  }
}
