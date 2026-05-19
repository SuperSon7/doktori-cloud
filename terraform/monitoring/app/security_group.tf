# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------
resource "aws_security_group" "monitoring" {
  name        = "${var.project_name}-monitoring-sg"
  description = "Monitoring server SG"
  vpc_id      = local.base.vpc_id

  # Prometheus HTTP/remote_write (9090): 피어링된 환경 VPC에서만 허용
  ingress {
    description = "from peered env VPCs to Prometheus HTTP/remote_write"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = var.peered_vpc_cidrs
  }

  # Grafana (3000): 관리자/VPN CIDR에서만 허용
  ingress {
    description = "from admin or VPN CIDRs to Grafana UI"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.allowed_admin_cidrs
  }

  # Loki (3100): 피어링된 환경 VPC에서만 허용
  ingress {
    description = "from peered env VPCs to Loki push API"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = var.peered_vpc_cidrs
  }

  egress {
    description = "from monitoring EC2 to outbound internet and peered services"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-monitoring-sg"
    Service = "monitoring"
  }

  lifecycle {
    create_before_destroy = true
  }
}
