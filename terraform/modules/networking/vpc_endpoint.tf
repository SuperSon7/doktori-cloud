resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.vpc_interface_endpoints)

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.this[var.vpc_endpoint_subnet_key].id]
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-${replace(each.value, ".", "-")}"
  }
}

# VPC Endpoint — Gateway (S3)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    [aws_route_table.public.id],
    [for k, v in aws_route_table.private : v.id],
  )

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-s3"
  }
}
