resource "aws_vpc_peering_connection" "prod_to_mgmt" {
  vpc_id      = module.networking.vpc_id
  peer_vpc_id = local.mgmt_vpc_id
  auto_accept = true

  tags = { Name = "${var.project_name}-${var.environment}-to-mgmt" }
}
