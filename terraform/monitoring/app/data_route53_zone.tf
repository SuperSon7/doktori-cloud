data "aws_route53_zone" "mgmt" {
  name         = local.base.mgmt_zone_name
  private_zone = true
}
