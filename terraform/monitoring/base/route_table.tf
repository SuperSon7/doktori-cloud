# -----------------------------------------------------------------------------
# Route Tables
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.mgmt.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.mgmt.id
  }

  tags = { Name = "${var.project_name}-mgmt-public-rt" }

  lifecycle {
    # VPC peering route는 aws_route 리소스로 별도 관리
    ignore_changes = [route]
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.mgmt.id

  tags = { Name = "${var.project_name}-mgmt-private-rt" }

  lifecycle {
    # VPC peering route는 aws_route 리소스로 별도 관리
    ignore_changes = [route]
  }
}
