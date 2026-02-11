# -----------------------------------------------------------------------------
# Security Group for EC2 Instance
# -----------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${var.project_name}-${local.environment}-app-sg"
  description = "Security group for application server"
  vpc_id      = aws_vpc.main.id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = concat(var.allowed_admin_cidrs, ["0.0.0.0/0"])
  }

  # HTTP
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
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

  # AI Service
  ingress {
    description = "AI Service"
    from_port   = var.ai_port
    to_port     = var.ai_port
    protocol    = "tcp"
    cidr_blocks = var.allowed_admin_cidrs
  }

  # AI Service (8001)
  ingress {
    from_port   = 8001
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["211.244.225.166/32"]
  }

  # Spring Boot Blue (monitoring access)
  ingress {
    description = "Spring Boot (Blue)"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.monitoring_server_ips
  }

  # Spring Boot Green (monitoring access)
  ingress {
    description = "Spring Boot (Green)"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = var.monitoring_server_ips
  }

  # Grafana (Monitoring)
  ingress {
    description = "Grafana (Monitoring)"
    from_port   = 3003
    to_port     = 3003
    protocol    = "tcp"
    cidr_blocks = concat(var.allowed_admin_cidrs, ["122.40.177.81/32"])
  }

  # Prometheus (Monitoring)
  ingress {
    description = "Prometheus (Monitoring)"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = var.allowed_admin_cidrs
  }

  # Loki (Log aggregation)
  ingress {
    description = "Loki"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = ["211.244.225.166/32"]
  }

  # Promtail (Log shipping)
  ingress {
    description = "Promtail"
    from_port   = 9080
    to_port     = 9080
    protocol    = "tcp"
    cidr_blocks = ["211.244.225.166/32"]
  }

  # Node Exporter
  ingress {
    description = "Node Exporter port"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = var.monitoring_server_ips
  }

  # MySQL Exporter
  ingress {
    description = "MySQL Exporter"
    from_port   = 9104
    to_port     = 9104
    protocol    = "tcp"
    cidr_blocks = concat(["211.244.225.166/32"], var.monitoring_server_ips)
  }

  # Nginx Exporter
  ingress {
    description = "Nginx Exporter"
    from_port   = 9113
    to_port     = 9113
    protocol    = "tcp"
    cidr_blocks = var.monitoring_server_ips
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
    Name = "${var.project_name}-${local.environment}-app-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}
