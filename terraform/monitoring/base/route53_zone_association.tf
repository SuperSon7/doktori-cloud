resource "aws_route53_zone_association" "mgmt_phz_env" {
  for_each = data.aws_vpc_peering_connection.env

  zone_id = aws_route53_zone.mgmt.id
  vpc_id  = each.value.vpc_id
}
