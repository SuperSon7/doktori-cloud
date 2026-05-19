# S3 — 버킷이 이 레이어(data)에 있으므로 여기서 write
resource "aws_ssm_parameter" "aws_s3_bucket_name" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_BUCKET_NAME"
  type  = "String"
  value = module.storage.bucket_names["app"]
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_S3_BUCKET_NAME" }
}

resource "aws_ssm_parameter" "aws_s3_db_backup" {
  name  = "/${var.project_name}/${var.environment}/AWS_S3_DB_BACKUP"
  type  = "String"
  value = module.storage.bucket_names["app"] # backup/ 폴더 공유
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

resource "aws_ssm_parameter" "spring_redis_sentinel_master" {
  count = var.enable_data_ha ? 1 : 0

  name  = "/${var.project_name}/${var.environment}/SPRING_REDIS_SENTINEL_MASTER"
  type  = "String"
  value = local.redis_sentinel_master
  tags  = { Name = "${var.project_name}-${var.environment}-SPRING_REDIS_SENTINEL_MASTER" }
}

resource "aws_ssm_parameter" "spring_redis_sentinel_nodes" {
  count = var.enable_data_ha ? 1 : 0

  name  = "/${var.project_name}/${var.environment}/SPRING_REDIS_SENTINEL_NODES"
  type  = "String"
  value = join(",", local.redis_sentinel_nodes)
  tags  = { Name = "${var.project_name}-${var.environment}-SPRING_REDIS_SENTINEL_NODES" }
}

resource "aws_ssm_parameter" "spring_rabbitmq_addresses" {
  name  = "/${var.project_name}/${var.environment}/SPRING_RABBITMQ_ADDRESSES"
  type  = "String"
  value = join(",", local.rabbitmq_addresses)
  tags  = { Name = "${var.project_name}-${var.environment}-SPRING_RABBITMQ_ADDRESSES" }
}

resource "aws_ssm_parameter" "mongo_admin_username" {
  name  = "/${var.project_name}/${var.environment}/MONGO_ADMIN_USERNAME"
  type  = "String"
  value = "doktori_admin"
  tags  = { Name = "${var.project_name}-${var.environment}-MONGO_ADMIN_USERNAME" }
}

resource "aws_ssm_parameter" "mongo_admin_password" {
  name  = "/${var.project_name}/${var.environment}/MONGO_ADMIN_PASSWORD"
  type  = "SecureString"
  value = random_password.mongo_admin.result
  tags  = { Name = "${var.project_name}-${var.environment}-MONGO_ADMIN_PASSWORD" }

  lifecycle {
    # RDS DB_PASSWORD와 동일하게 초기 생성 후 수동 교체 가능하도록 유지
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "mongo_username" {
  name  = "/${var.project_name}/${var.environment}/MONGO_USERNAME"
  type  = "String"
  value = local.mongo_username
  tags  = { Name = "${var.project_name}-${var.environment}-MONGO_USERNAME" }
}

resource "aws_ssm_parameter" "mongo_password" {
  name  = "/${var.project_name}/${var.environment}/MONGO_PASSWORD"
  type  = "SecureString"
  value = random_password.mongo.result
  tags  = { Name = "${var.project_name}-${var.environment}-MONGO_PASSWORD" }

  lifecycle {
    # RDS DB_PASSWORD와 동일하게 초기 생성 후 수동 교체 가능하도록 유지
    ignore_changes = [value]
  }
}

# Python SQLAlchemy URL (패스워드 포함 — value_wo로 state 저장 방지)
resource "aws_ssm_parameter" "ai_db_url" {
  name             = "/${var.project_name}/${var.environment}/AI_DB_URL"
  type             = "SecureString"
  value_wo         = "mysql+pymysql://${module.database.db_username}:${ephemeral.aws_ssm_parameter.db_password.value}@${module.database.proxy_host}/${var.db_name}?charset=utf8mb4"
  value_wo_version = 1
  tags             = { Name = "${var.project_name}-${var.environment}-AI_DB_URL" }
}

resource "aws_ssm_parameter" "mongo_uri" {
  name             = "/${var.project_name}/${var.environment}/MONGO_URI"
  type             = "SecureString"
  value_wo         = "mongodb://${local.mongo_username}:${ephemeral.aws_ssm_parameter.mongo_password.value}@mongodb.${local.net.internal_zone_name}:27017/${local.mongo_db_name}?authSource=admin"
  value_wo_version = 1
  tags             = { Name = "${var.project_name}-${var.environment}-MONGO_URI" }
}

# Spring JDBC URL (패스워드 없음 — Spring은 DB_PASSWORD를 별도로 읽음)
resource "aws_ssm_parameter" "db_url" {
  name  = "/${var.project_name}/${var.environment}/DB_URL"
  type  = "String"
  value = "jdbc:mysql://${module.database.proxy_host}/${var.db_name}?serverTimezone=Asia/Seoul&sslMode=REQUIRED"
  tags  = { Name = "${var.project_name}-${var.environment}-DB_URL" }
}
