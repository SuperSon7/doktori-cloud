# -----------------------------------------------------------------------------
# Target Group & Target
# -----------------------------------------------------------------------------
resource "aws_db_proxy_default_target_group" "main" {
  count = var.enable_rds_proxy ? 1 : 0

  db_proxy_name = aws_db_proxy.main[0].name

  connection_pool_config {
    max_connections_percent      = var.rds_proxy_max_connections_percent
    max_idle_connections_percent = var.rds_proxy_max_idle_connections_percent
    connection_borrow_timeout    = var.rds_proxy_connection_borrow_timeout
  }
}
