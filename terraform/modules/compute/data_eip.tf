# -----------------------------------------------------------------------------
# Elastic IPs (conditional)
# -----------------------------------------------------------------------------
data "aws_eip" "existing" {
  for_each = {
    for k, v in var.services : k => v
    if v.associate_eip && v.existing_eip_allocation_id != ""
  }

  id = each.value.existing_eip_allocation_id
}
