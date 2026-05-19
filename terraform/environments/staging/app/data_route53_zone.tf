data "aws_route53_zone" "internal" {
  name         = "${var.environment}.${var.project_name}.internal"
  private_zone = true
  vpc_id       = data.aws_vpc.main.id
}
