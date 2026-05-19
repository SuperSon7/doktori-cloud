data "aws_route_table" "private_primary" {
  vpc_id = data.aws_vpc.main.id
  tags   = { Name = "${var.project_name}-${var.environment}-private-primary-rt" }
}
