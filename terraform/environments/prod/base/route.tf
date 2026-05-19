# --- prod → mgmt routes ---
# public route table
resource "aws_route" "prod_public_to_mgmt" {
  route_table_id            = module.networking.public_route_table_id
  destination_cidr_block    = local.mgmt_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.prod_to_mgmt.id
}

# private route tables (all AZs)
resource "aws_route" "prod_private_to_mgmt" {
  for_each = module.networking.private_route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = local.mgmt_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.prod_to_mgmt.id
}
