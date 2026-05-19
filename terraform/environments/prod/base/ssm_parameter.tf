# -----------------------------------------------------------------------------
# SSM — Terraform이 직접 쓰는 값 (CHANGE_ME 불필요, ignore_changes 없음)
# -----------------------------------------------------------------------------
resource "aws_ssm_parameter" "aws_region" {
  name  = "/${var.project_name}/${var.environment}/AWS_REGION"
  type  = "String"
  value = var.aws_region
  tags  = { Name = "${var.project_name}-${var.environment}-AWS_REGION" }
}

resource "aws_ssm_parameter" "ecr_registry" {
  name  = "/${var.project_name}/${var.environment}/ECR_REGISTRY"
  type  = "String"
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  tags  = { Name = "${var.project_name}-${var.environment}-ECR_REGISTRY" }
}

resource "aws_ssm_parameter" "spring_redis_port" {
  name  = "/${var.project_name}/${var.environment}/SPRING_REDIS_PORT"
  type  = "String"
  value = "6379"
  tags  = { Name = "${var.project_name}-${var.environment}-SPRING_REDIS_PORT" }
}

resource "aws_ssm_parameter" "spring_rabbitmq_port" {
  name  = "/${var.project_name}/${var.environment}/SPRING_RABBITMQ_PORT"
  type  = "String"
  value = "5672"
  tags  = { Name = "${var.project_name}-${var.environment}-SPRING_RABBITMQ_PORT" }
}
