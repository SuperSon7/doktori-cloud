resource "aws_internet_gateway" "loadtest" {
  vpc_id = aws_vpc.loadtest.id
  tags   = { Name = "${var.project_name}-loadtest-igw" }
}
