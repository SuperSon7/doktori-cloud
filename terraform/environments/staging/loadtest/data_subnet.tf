data "aws_subnet" "public" {
  vpc_id = data.aws_vpc.main.id
  tags   = { Name = "${var.project_name}-${var.environment}-public" }
}
