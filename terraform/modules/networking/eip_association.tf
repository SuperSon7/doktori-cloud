resource "aws_eip_association" "nat" {
  for_each = aws_eip.nat

  allocation_id = aws_eip.nat[each.key].id
  instance_id   = aws_instance.nat[each.key].id
}
