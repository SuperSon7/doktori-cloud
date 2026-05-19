resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}

# private 서브넷 → env VPC (monitoring EC2 outbound)
resource "aws_route" "private_to_env" {
  for_each = data.aws_vpc_peering_connection.env

  route_table_id            = aws_route_table.private.id
  destination_cidr_block    = each.value.cidr_block
  vpc_peering_connection_id = each.value.id
}

# public 서브넷 → env VPC (WireGuard VPN 클라이언트가 peered VPC에 접근하기 위한 route)
resource "aws_route" "public_to_env" {
  for_each = data.aws_vpc_peering_connection.env

  route_table_id            = aws_route_table.public.id
  destination_cidr_block    = each.value.cidr_block
  vpc_peering_connection_id = each.value.id
}
