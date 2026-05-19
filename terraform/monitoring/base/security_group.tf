resource "aws_security_group" "nat" {
  name        = "${var.project_name}-mgmt-nat-sg"
  description = "mgmt NAT instance - WireGuard VPN + private subnet NAT forwarding"
  vpc_id      = aws_vpc.mgmt.id

  ingress {
    description = "from mgmt VPC CIDR to NAT forwarding"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "from internet to WireGuard VPN"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "from mgmt NAT to outbound destinations"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-mgmt-nat-sg"
    Service = "nat-vpn"
  }

  lifecycle {
    create_before_destroy = true
  }
}
