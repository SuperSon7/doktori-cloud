resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.project_name}-mgmt-nat-eip" }
}
