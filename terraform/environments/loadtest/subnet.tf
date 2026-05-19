resource "aws_subnet" "public" {
  count                   = min(var.runner_count, 2)
  vpc_id                  = aws_vpc.loadtest.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-loadtest-public-${data.aws_availability_zones.available.names[count.index]}"
  }
}
