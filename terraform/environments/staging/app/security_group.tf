resource "aws_security_group" "h_k8s_master" {
  count = var.create_h_k8s_nodes ? 1 : 0

  name_prefix = "${var.project_name}-${var.environment}-h-k8s-master-"
  description = "h-k8s master node ingress"
  vpc_id      = local.net.vpc_id

  egress {
    description = "from h-k8s master to outbound destinations"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "h-k8s-master-sg"
    Service = "k8s-cp"
  }
}

resource "aws_security_group" "h_k8s_worker" {
  count = var.create_h_k8s_nodes ? 1 : 0

  name_prefix = "${var.project_name}-${var.environment}-h-k8s-worker-"
  description = "h-k8s worker node ingress"
  vpc_id      = local.net.vpc_id

  egress {
    description = "from h-k8s worker to outbound destinations"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "h-k8s-worker-sg"
    Service = "k8s-worker"
  }
}
