resource "aws_security_group" "k6_runner" {
  name_prefix = "${var.project_name}-${var.environment}-k6-runner-"
  description = "Security group for k6 load test runners"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "from k6 runners to loadtest Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "from k6 runner to outbound targets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-k6-runner-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}
