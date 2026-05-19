# apply 시점에만 SSM에서 비밀번호를 읽어옴 — state에 저장되지 않음
ephemeral "aws_ssm_parameter" "db_password" {
  arn = aws_ssm_parameter.db_password.arn
}
