resource "aws_internet_gateway" "mgmt" {
  vpc_id = aws_vpc.mgmt.id

  tags = { Name = "${var.project_name}-mgmt-igw" }
}
