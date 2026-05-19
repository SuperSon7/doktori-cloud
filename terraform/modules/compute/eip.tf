resource "aws_eip" "this" {
  for_each = {
    for k, v in var.services : k => v
    if v.associate_eip && v.existing_eip_allocation_id == ""
  }
  domain = "vpc"

  tags = {
    Name    = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}-eip"
    Service = each.key
  }
}
