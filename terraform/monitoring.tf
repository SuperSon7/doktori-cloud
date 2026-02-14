# -----------------------------------------------------------------------------
# Default VPC (data source - not managed, just referenced)
# -----------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

# -----------------------------------------------------------------------------
# Security Group for Monitoring Instances
# -----------------------------------------------------------------------------
resource "aws_security_group" "monitoring" {
  name        = "doktori-monitoring.sg"
  description = "doktori monitoring security group"
  vpc_id      = data.aws_vpc.default.id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # WireGuard VPN
  ingress {
    description = "WireGuard VPN"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Grafana
  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["122.40.177.81/32", "0.0.0.0/0"]
  }

  # Prometheus
  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["122.40.177.81/32", "0.0.0.0/0"]
  }

  # Alertmanager
  ingress {
    description = "Alertmanager"
    from_port   = 9093
    to_port     = 9093
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Loki
  ingress {
    description = "Loki"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = ["52.79.205.195/32", "3.37.180.158/32"]
  }

  # MySQL Exporter
  ingress {
    description = "MySQL Exporter"
    from_port   = 9104
    to_port     = 9104
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Nginx Exporter
  ingress {
    description = "Nginx Exporter"
    from_port   = 9113
    to_port     = 9113
    protocol    = "tcp"
    cidr_blocks = ["52.79.205.195/32"]
  }

  # Outbound - Allow all
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "doktori-monitoring-sg"
  }
}

# -----------------------------------------------------------------------------
# Monitoring Instance (arm64)
# -----------------------------------------------------------------------------
resource "aws_instance" "monitoring1" {
  ami                    = "ami-04f06fb5ae9dcc778"
  instance_type          = "t4g.small"
  key_name               = "doktori-monitoring"
  subnet_id              = "subnet-0a34b53f9a1a8d27d"
  vpc_security_group_ids = [aws_security_group.monitoring.id]

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-monitoring"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

# -----------------------------------------------------------------------------
# Elastic IPs for Monitoring
# -----------------------------------------------------------------------------
resource "aws_eip" "monitoring1" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-monitoring1-eip"
  }
}

resource "aws_eip_association" "monitoring1" {
  allocation_id = aws_eip.monitoring1.id
  instance_id   = aws_instance.monitoring1.id
}