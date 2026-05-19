# ── Security Group ──────────────────────────────────────────────────────────

resource "aws_security_group" "k6_runner" {
  name_prefix = "${var.project_name}-loadtest-k6-"
  description = "k6 load test runners and monitoring"
  vpc_id      = aws_vpc.loadtest.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "from internet to loadtest Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "from loadtest monitoring to outbound destinations"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-loadtest-k6-sg" }

  lifecycle { create_before_destroy = true }
}
