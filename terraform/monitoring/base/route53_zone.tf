# -----------------------------------------------------------------------------
# Private Hosted Zone — mgmt.{project}.internal
# peered VPC association은 aws_route53_zone_association으로 추가 → ignore_changes로 drift 방지
# -----------------------------------------------------------------------------
resource "aws_route53_zone" "mgmt" {
  name = "mgmt.${var.project_name}.internal"

  vpc {
    vpc_id = aws_vpc.mgmt.id
  }

  tags = {
    Name    = "mgmt.${var.project_name}.internal"
    Service = "monitoring"
  }

  lifecycle {
    prevent_destroy = true
    # peered VPC association은 aws_route53_zone_association으로 추가되므로
    # Terraform이 이 변경을 drift로 감지하고 제거하지 않도록 ignore
    ignore_changes = [vpc]
  }
}
