# NAT route for private subnets (per AZ)
resource "aws_route" "private_nat" {
  for_each = local.nat_instances

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[each.key].primary_network_interface_id
}
