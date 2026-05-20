resource "aws_eip_association" "this" {
  for_each = {
    for k, v in var.services : k => v
    if v.associate_eip && v.existing_eip_allocation_id == ""
  }

  allocation_id = aws_eip.this[each.key].id
  instance_id   = aws_instance.this[each.key].id
}

resource "aws_eip_association" "existing" {
  for_each = {
    for k, v in var.services : k => v
    if v.associate_eip && v.existing_eip_allocation_id != ""
  }

  allocation_id = data.aws_eip.existing[each.key].id
  instance_id   = aws_instance.this[each.key].id
}
