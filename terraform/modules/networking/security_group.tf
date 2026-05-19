resource "aws_security_group" "nat" {
  name_prefix = "${var.project_name}-${var.environment}-nat-"
  description = "NAT instance - forward traffic from private subnets"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "All traffic from VPC (NAT forwarding)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  dynamic "ingress" {
    for_each = var.nat_extra_ingress
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
    }
  }

  egress {
    description = "from NAT SG to outbound destinations"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-nat-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# VPC Endpoints — Interface (SSM, ECR, CloudWatch Logs)
# -----------------------------------------------------------------------------
resource "aws_security_group" "vpc_endpoints" {
  count = length(var.vpc_interface_endpoints) > 0 ? 1 : 0

  name_prefix = "${var.project_name}-${var.environment}-vpce-"
  description = "Security group for VPC endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-sg"
  }
}
