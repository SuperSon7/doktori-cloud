resource "aws_route_table" "public" {
  vpc_id = aws_vpc.loadtest.id
  tags   = { Name = "${var.project_name}-loadtest-public-rt" }
}
