# -----------------------------------------------------------------------------
# Internal NLB (Kubernetes API endpoint)
# -----------------------------------------------------------------------------
resource "aws_lb" "nlb" {
  name                             = "${var.project_name}-${var.environment}-k8s-nlb"
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = var.private_subnet_ids
  enable_cross_zone_load_balancing = true

  tags = {
    Name    = "${var.project_name}-${var.environment}-k8s-nlb"
    Service = "k8s"
  }
}
