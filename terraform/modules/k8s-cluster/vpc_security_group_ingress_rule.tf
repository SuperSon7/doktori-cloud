# --- Master ingress rules ---

# apiserver from workers
resource "aws_vpc_security_group_ingress_rule" "master_apiserver_from_worker" {
  security_group_id            = aws_security_group.master.id
  description                  = "from worker SG to master kube-apiserver"
  from_port                    = 6443
  to_port                      = 6443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.worker.id
}

# apiserver from VPC (SSM, bastion)
resource "aws_vpc_security_group_ingress_rule" "master_apiserver_from_vpc" {
  security_group_id = aws_security_group.master.id
  description       = "from VPC CIDR to master kube-apiserver"
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

# apiserver from master (HA etcd communication)
resource "aws_vpc_security_group_ingress_rule" "master_apiserver_from_self" {
  security_group_id            = aws_security_group.master.id
  description                  = "from master SG to master kube-apiserver"
  from_port                    = 6443
  to_port                      = 6443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# etcd peer/client
resource "aws_vpc_security_group_ingress_rule" "master_etcd" {
  security_group_id            = aws_security_group.master.id
  description                  = "from master SG to etcd peer/client"
  from_port                    = 2379
  to_port                      = 2380
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# kubelet from master
resource "aws_vpc_security_group_ingress_rule" "master_kubelet_from_self" {
  security_group_id            = aws_security_group.master.id
  description                  = "from master SG to master kubelet API"
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# kubelet from worker
resource "aws_vpc_security_group_ingress_rule" "master_kubelet_from_worker" {
  security_group_id            = aws_security_group.master.id
  description                  = "from worker SG to master kubelet API"
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.worker.id
}

# scheduler
resource "aws_vpc_security_group_ingress_rule" "master_scheduler" {
  security_group_id            = aws_security_group.master.id
  description                  = "from master SG to kube-scheduler"
  from_port                    = 10259
  to_port                      = 10259
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# controller-manager
resource "aws_vpc_security_group_ingress_rule" "master_controller" {
  security_group_id            = aws_security_group.master.id
  description                  = "from master SG to kube-controller-manager"
  from_port                    = 10257
  to_port                      = 10257
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# Calico VXLAN from workers
resource "aws_vpc_security_group_ingress_rule" "master_vxlan_from_worker" {
  security_group_id            = aws_security_group.master.id
  description                  = "from worker SG to master Calico VXLAN"
  from_port                    = 4789
  to_port                      = 4789
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.worker.id
}

# Calico VXLAN from self
resource "aws_vpc_security_group_ingress_rule" "master_vxlan_from_self" {
  security_group_id            = aws_security_group.master.id
  description                  = "from master SG to master Calico VXLAN"
  from_port                    = 4789
  to_port                      = 4789
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.master.id
}

# Calico Typha from workers
resource "aws_vpc_security_group_ingress_rule" "master_typha_from_worker" {
  security_group_id            = aws_security_group.master.id
  description                  = "from worker SG to master Calico Typha"
  from_port                    = 5473
  to_port                      = 5473
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.worker.id
}

# Calico Typha from self
resource "aws_vpc_security_group_ingress_rule" "master_typha_from_self" {
  security_group_id            = aws_security_group.master.id
  description                  = "from master SG to master Calico Typha"
  from_port                    = 5473
  to_port                      = 5473
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# --- Worker ingress rules ---

# kubelet from master
resource "aws_vpc_security_group_ingress_rule" "worker_kubelet" {
  security_group_id            = aws_security_group.worker.id
  description                  = "from master SG to worker kubelet API"
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# kubelet from workers (metrics-server → kubelet 메트릭 수집)
resource "aws_vpc_security_group_ingress_rule" "worker_kubelet_from_self" {
  security_group_id            = aws_security_group.worker.id
  description                  = "from worker SG to worker kubelet API"
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.worker.id
}

# NodePort from VPC
resource "aws_vpc_security_group_ingress_rule" "worker_nodeport" {
  security_group_id = aws_security_group.worker.id
  description       = "from VPC CIDR to worker NodePort range"
  from_port         = 30000
  to_port           = 32767
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

# Worker HTTP NodePort from VPC CIDR. Public ALB access can be narrowed further
# with an environment-level SG reference rule.
resource "aws_vpc_security_group_ingress_rule" "worker_nodeport_from_external" {
  security_group_id = aws_security_group.worker.id
  description       = "from VPC CIDR to worker HTTP NodePort"
  from_port         = var.worker_node_port
  to_port           = var.worker_node_port
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

# Calico VXLAN from master
resource "aws_vpc_security_group_ingress_rule" "worker_vxlan_from_master" {
  security_group_id            = aws_security_group.worker.id
  description                  = "from master SG to worker Calico VXLAN"
  from_port                    = 4789
  to_port                      = 4789
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.master.id
}

# Calico VXLAN from self
resource "aws_vpc_security_group_ingress_rule" "worker_vxlan_from_self" {
  security_group_id            = aws_security_group.worker.id
  description                  = "from worker SG to worker Calico VXLAN"
  from_port                    = 4789
  to_port                      = 4789
  ip_protocol                  = "udp"
  referenced_security_group_id = aws_security_group.worker.id
}

# Calico Typha from master
resource "aws_vpc_security_group_ingress_rule" "worker_typha_from_master" {
  security_group_id            = aws_security_group.worker.id
  description                  = "from master SG to worker Calico Typha"
  from_port                    = 5473
  to_port                      = 5473
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.master.id
}

# Calico Typha from self
resource "aws_vpc_security_group_ingress_rule" "worker_typha_from_self" {
  security_group_id            = aws_security_group.worker.id
  description                  = "from worker SG to worker Calico Typha"
  from_port                    = 5473
  to_port                      = 5473
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.worker.id
}
