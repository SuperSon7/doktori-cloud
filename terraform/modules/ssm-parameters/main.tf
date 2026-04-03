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
    # 초기값 "CHANGE_ME"는 껍데기 — CLI로 실제 값을 주입하므로 Terraform이 덮어쓰지 않도록 ignore
    ignore_changes = [value, description]
  }
}