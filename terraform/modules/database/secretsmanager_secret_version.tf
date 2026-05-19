resource "aws_secretsmanager_secret_version" "db_credentials" {
  count = var.enable_rds_proxy ? 1 : 0

  secret_id = aws_secretsmanager_secret.db_credentials[0].id
  # secret_string_wo: apply 시점에만 값을 씀 — state에 저장되지 않음
  # DB 비밀번호를 회전해 Proxy secret도 갱신해야 할 때 version을 올린다.
  secret_string_wo = jsonencode({
    username = aws_db_instance.main.username
    password = ephemeral.aws_ssm_parameter.db_password.value
  })
  secret_string_wo_version = 1
}
