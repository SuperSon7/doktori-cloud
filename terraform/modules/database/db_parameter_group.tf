# -----------------------------------------------------------------------------
# DB Parameter Group
# -----------------------------------------------------------------------------
resource "aws_db_parameter_group" "main" {
  name        = "${var.project_name}-${var.environment}-${replace(var.db_parameter_group_family, ".", "")}"
  family      = var.db_parameter_group_family
  description = "MySQL parameter group for ${var.project_name} ${var.environment}"

  tags = {
    Name    = "${var.project_name}-${var.environment}-${replace(var.db_parameter_group_family, ".", "")}"
    Service = "db"
  }

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  parameter {
    name  = "time_zone"
    value = "Asia/Seoul"
  }

  dynamic "parameter" {
    for_each = var.db_extra_parameters
    content {
      name         = parameter.value.name
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }
}
