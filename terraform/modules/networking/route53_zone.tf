# VPC Endpoint — Gateway (S3)
# -----------------------------------------------------------------------------
# Route53 Private Hosted Zone
# -----------------------------------------------------------------------------
resource "aws_route53_zone" "internal" {
  name = var.internal_domain

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = {
    Name = var.internal_domain
  }
}
