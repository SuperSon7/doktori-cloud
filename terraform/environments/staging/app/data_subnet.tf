data "aws_subnet" "public" {
  vpc_id = data.aws_vpc.main.id
  tags   = { Name = "${var.project_name}-${var.environment}-public" }
}

data "aws_subnet" "private_app" {
  vpc_id = data.aws_vpc.main.id
  tags   = { Name = "${var.project_name}-${var.environment}-private-app" }
}

data "aws_subnet" "private_db" {
  vpc_id = data.aws_vpc.main.id
  tags   = { Name = "${var.project_name}-${var.environment}-private-db" }
}

data "aws_subnet" "private_rds" {
  vpc_id = data.aws_vpc.main.id
  tags   = { Name = "${var.project_name}-${var.environment}-private-rds" }
}

data "aws_subnet" "private_k8s_a" {
  vpc_id = data.aws_vpc.main.id
  tags   = { Name = "${var.project_name}-${var.environment}-private-k8s-a" }
}

data "aws_subnet" "private_k8s_b" {
  vpc_id = data.aws_vpc.main.id
  tags   = { Name = "${var.project_name}-${var.environment}-private-k8s-b" }
}
