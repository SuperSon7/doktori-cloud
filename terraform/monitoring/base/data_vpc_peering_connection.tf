data "aws_vpc_peering_connection" "env" {
  for_each = toset(data.aws_vpc_peering_connections.env_peerings.ids)
  id       = each.value
}
