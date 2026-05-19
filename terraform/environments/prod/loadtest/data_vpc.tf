data "aws_vpc" "main" {
  tags = {
    Name = "${var.project_name}-${var.environment}-vpc"
  }
}
