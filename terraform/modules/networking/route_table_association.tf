# Route Table Associations
resource "aws_route_table_association" "this" {
  for_each = var.subnets

  subnet_id = aws_subnet.this[each.key].id
  route_table_id = (
    each.value.tier == "public"
    ? aws_route_table.public.id
    : aws_route_table.private[local.subnet_nat_key[each.key]].id
  )
}
