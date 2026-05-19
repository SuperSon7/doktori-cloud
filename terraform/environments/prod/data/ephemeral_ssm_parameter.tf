# apply 시점에만 Mongo 앱 비밀번호 읽기 — URI에 포함되지만 state에는 저장하지 않음
ephemeral "aws_ssm_parameter" "mongo_password" {
  arn = aws_ssm_parameter.mongo_password.arn
}

# -----------------------------------------------------------------------------
# SSM — DB 접속 정보 (RDS apply 후 Terraform이 직접 write)
# -----------------------------------------------------------------------------

# apply 시점에만 패스워드 읽기 — state에 저장되지 않음
ephemeral "aws_ssm_parameter" "db_password" {
  arn = module.database.db_password_ssm_arn
}
