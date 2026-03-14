# =============================================================================
# SSM Parameter Store — 껍데기 정의 (값은 CLI로 관리)
# =============================================================================
resource "aws_ssm_parameter" "this" {
  for_each = merge(var.common_parameters, var.extra_parameters)

  name  = "/${var.project_name}/${var.environment}/${each.key}"
  type  = each.value.type
  value = "CHANGE_ME"

  tags = {
    Name = "${var.project_name}-${var.environment}-${each.key}"
  }

  lifecycle {
    ignore_changes = [value, description]
  }
}