resource "aws_route_table" "private" {
  for_each = local.nat_instances

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.environment}-private-${each.key}-rt"
  }

  lifecycle {
    ignore_changes = [route]
  }
}

# -----------------------------------------------------------------------------
# Route Tables
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-public-rt"
  }

  # 별도 aws_route 리소스(VPC peering 등)로 추가된 route와 충돌 방지
  lifecycle {
    ignore_changes = [route]
  }
}
