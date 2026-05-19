# static 값은 Terraform이 직접 write — CLI 주입 불필요
resource "aws_ssm_parameter" "spring_rabbitmq_port" {
  name  = "/${var.project_name}/${var.environment}/SPRING_RABBITMQ_PORT"
  type  = "String"
  value = "5672"
  tags  = { Name = "${var.project_name}-${var.environment}-SPRING_RABBITMQ_PORT" }
}

resource "aws_ssm_parameter" "spring_redis_port" {
  name  = "/${var.project_name}/${var.environment}/SPRING_REDIS_PORT"
  type  = "String"
  value = "6379"
  tags  = { Name = "${var.project_name}-${var.environment}-SPRING_REDIS_PORT" }
}

resource "aws_ssm_parameter" "qdrant_url" {
  name  = "/${var.project_name}/${var.environment}/QDRANT_URL"
  type  = "String"
  value = "http://ai-qdrant.${module.networking.internal_zone_name}:6333"

  tags = {
    Name = "${var.project_name}-${var.environment}-QDRANT_URL"
  }

  lifecycle {
    # CLI로 실제 값을 주입하므로 Terraform이 덮어쓰지 않도록 ignore
    ignore_changes = [value, description]
  }
}

resource "aws_ssm_parameter" "qdrant_api_key" {
  name = "/${var.project_name}/${var.environment}/QDRANT_API_KEY"
  type = "SecureString"
  # 초기 생성 시에만 ephemeral 랜덤 값을 주입 — value_wo: state에 시크릿이 저장되지 않음
  # AWS provider >= 5.78.0 필요. 값을 교체할 때는 value_wo_version을 올린다.
  value_wo         = ephemeral.random_password.qdrant_api_key.result
  value_wo_version = 1

  tags = {
    Name = "${var.project_name}-${var.environment}-QDRANT_API_KEY"
  }

  lifecycle {
    # 랜덤 값을 그대로 API key로 사용 — apply마다 키가 교체되면 실행 중인 Qdrant와 불일치하므로 ignore
    ignore_changes = [value_wo, value_wo_version]
  }
}

resource "aws_ssm_parameter" "qdrant_location" {
  name  = "/${var.project_name}/${var.environment}/QDRANT_LOCATION"
  type  = "String"
  value = ":memory:"

  tags = {
    Name = "${var.project_name}-${var.environment}-QDRANT_LOCATION"
  }

  lifecycle {
    # CLI로 실제 값을 주입하므로 Terraform이 덮어쓰지 않도록 ignore
    ignore_changes = [value, description]
  }
}

resource "aws_ssm_parameter" "qdrant_collection_discussion" {
  name  = "/${var.project_name}/${var.environment}/QDRANT_COLLECTION_DISCUSSION"
  type  = "String"
  value = "discussion_topics_dev"

  tags = {
    Name = "${var.project_name}-${var.environment}-QDRANT_COLLECTION_DISCUSSION"
  }

  lifecycle {
    # CLI로 실제 값을 주입하므로 Terraform이 덮어쓰지 않도록 ignore
    ignore_changes = [value, description]
  }
}

resource "aws_ssm_parameter" "qdrant_collection_reco" {
  name  = "/${var.project_name}/${var.environment}/QDRANT_COLLECTION_RECO"
  type  = "String"
  value = "reco_meetings_dev"

  tags = {
    Name = "${var.project_name}-${var.environment}-QDRANT_COLLECTION_RECO"
  }

  lifecycle {
    # CLI로 실제 값을 주입하므로 Terraform이 덮어쓰지 않도록 ignore
    ignore_changes = [value, description]
  }
}
