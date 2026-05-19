# /* (default) → Frontend ASG (listener default action, 변경 없음)

# --- SG: Worker NodePort from ALB ---
resource "aws_vpc_security_group_ingress_rule" "worker_from_alb" {
  security_group_id            = module.k8s_cluster.worker_sg_id
  description                  = "from public ALB SG to k8s worker NGF NodePort"
  from_port                    = 30080
  to_port                      = 30080
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.frontend.alb_sg_id

  tags = { Name = "${var.project_name}-${var.environment}-worker-from-alb" }
}

# --- SG: AI from K8s workers ---
resource "aws_vpc_security_group_ingress_rule" "ai_from_k8s_worker" {
  security_group_id            = module.compute.security_group_ids["ai"]
  description                  = "from k8s worker SG to AI EC2 API"
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.k8s_cluster.worker_sg_id

  tags = { Name = "${var.project_name}-${var.environment}-ai-from-k8s-worker" }
}
