# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

# --- Master SG ---
resource "aws_security_group" "master" {
  name        = "${var.project_name}-${var.environment}-k8s-master-sg"
  description = "K8s control-plane node ingress"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-k8s-master-sg"
    Service = "k8s-cp"
  }
}

# --- Worker SG ---
resource "aws_security_group" "worker" {
  name        = "${var.project_name}-${var.environment}-k8s-worker-sg"
  description = "K8s worker node ingress"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-k8s-worker-sg"
    Service = "k8s-worker"
  }
}
