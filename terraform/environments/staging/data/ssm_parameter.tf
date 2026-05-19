# Python SQLAlchemy URL (패스워드 포함 — value_wo로 state 저장 방지)
resource "aws_ssm_parameter" "ai_db_url" {
  name             = "/${var.project_name}/${var.environment}/AI_DB_URL"
  type             = "SecureString"
  value_wo         = "mysql+pymysql://${module.database.db_username}:${ephemeral.aws_ssm_parameter.db_password.value}@${module.database.db_host}:${module.database.db_port}/${var.db_name}?charset=utf8mb4"
  value_wo_version = 1
  tags             = { Name = "${var.project_name}-${var.environment}-AI_DB_URL" }
}

resource "aws_ssm_parameter" "aws_s3_bucket_name" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_BUCKET_NAME"
  type  = "String"
  value = module.storage.bucket_names["app"]
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_S3_BUCKET_NAME" }
}

resource "aws_ssm_parameter" "aws_s3_db_backup" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_DB_BACKUP"
  type  = "String"
  value = module.storage.bucket_names["app"]
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_S3_DB_BACKUP" }
}

resource "aws_ssm_parameter" "aws_s3_enabled" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_ENABLED"
  type  = "String"
  value = "true"
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_S3_ENABLED" }
}

resource "aws_ssm_parameter" "aws_s3_endpoint" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_ENDPOINT"
  type  = "String"
  value = "https://s3.${var.aws_region}.amazonaws.com"
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_S3_ENDPOINT" }
}

# Spring JDBC URL (패스워드 없음, staging은 proxy 없이 직접 RDS)
resource "aws_ssm_parameter" "db_url" {
  name  = "/${var.project_name}/${var.environment}/DB_URL"
  type  = "String"
  value = "jdbc:mysql://${module.database.db_host}:${module.database.db_port}/${var.db_name}?serverTimezone=Asia/Seoul&sslMode=REQUIRED"
  tags  = { Name = "${var.project_name}-${var.environment}-DB_URL" }
}
