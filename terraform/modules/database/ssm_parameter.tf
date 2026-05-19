resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project_name}/${var.environment}/DB_PASSWORD"
  type  = "SecureString"
  value = random_password.db.result

  tags = {
    Name = "${var.project_name}-${var.environment}-db-password"
  }

  lifecycle {
    # 초기값(random_password)으로 첫 apply 후 수동 교체 가능하도록 ignore
    ignore_changes = [value]
  }
}
