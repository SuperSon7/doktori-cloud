resource "aws_security_group_rule" "h_k8s_master_apiserver_from_workers" {
  count = var.create_h_k8s_nodes ? 1 : 0

  type                     = "ingress"
  security_group_id        = aws_security_group.h_k8s_master[0].id
  source_security_group_id = aws_security_group.h_k8s_worker[0].id
  from_port                = 6443
  to_port                  = 6443
  protocol                 = "tcp"
  description              = "kube-apiserver from workers"
}

resource "aws_security_group_rule" "h_k8s_master_apiserver_from_vpc" {
  count = var.create_h_k8s_nodes ? 1 : 0

  type              = "ingress"
  security_group_id = aws_security_group.h_k8s_master[0].id
  cidr_blocks       = [local.net.vpc_cidr]
  from_port         = 6443
  to_port           = 6443
  protocol          = "tcp"
  description       = "kube-apiserver from staging VPC"
}

resource "aws_security_group_rule" "h_k8s_master_etcd_self" {
  count = var.create_h_k8s_nodes ? 1 : 0

  type              = "ingress"
  security_group_id = aws_security_group.h_k8s_master[0].id
  self              = true
  from_port         = 2379
  to_port           = 2380
  protocol          = "tcp"
  description       = "etcd self access"
}

resource "aws_security_group_rule" "h_k8s_master_kubelet_from_vpc" {
  count = var.create_h_k8s_nodes ? 1 : 0

  type              = "ingress"
  security_group_id = aws_security_group.h_k8s_master[0].id
  cidr_blocks       = [local.net.vpc_cidr]
  from_port         = 10250
  to_port           = 10250
  protocol          = "tcp"
  description       = "kubelet from staging VPC"
}

resource "aws_security_group_rule" "h_k8s_master_kubelet_self" {
  count = var.create_h_k8s_nodes ? 1 : 0

  type              = "ingress"
  security_group_id = aws_security_group.h_k8s_master[0].id
  self              = true
  from_port         = 10250
  to_port           = 10250
  protocol          = "tcp"
  description       = "kubelet self access"
}

resource "aws_security_group_rule" "h_k8s_master_scheduler_self" {
  count = var.create_h_k8s_nodes ? 1 : 0

  type              = "ingress"
  security_group_id = aws_security_group.h_k8s_master[0].id
  self              = true
  from_port         = 10259
  to_port           = 10259
  protocol          = "tcp"
  description       = "scheduler self access"
}

resource "aws_security_group_rule" "h_k8s_master_controller_self" {
  count = var.create_h_k8s_nodes ? 1 : 0

  type              = "ingress"
  security_group_id = aws_security_group.h_k8s_master[0].id
  self              = true
  from_port         = 10257
  to_port           = 10257
  protocol          = "tcp"
  description       = "controller manager self access"
}

resource "aws_security_group_rule" "h_k8s_master_vxlan_from_workers" {
  count = var.create_h_k8s_nodes ? 1 : 0

  type                     = "ingress"
  security_group_id        = aws_security_group.h_k8s_master[0].id
  source_security_group_id = aws_security_group.h_k8s_worker[0].id
  from_port                = 4789
  to_port                  = 4789
  protocol                 = "udp"
  description              = "Calico VXLAN from workers"
}

resource "aws_security_group_rule" "h_k8s_worker_kubelet_from_master" {
  count = var.create_h_k8s_nodes ? 1 : 0

  type                     = "ingress"
  security_group_id        = aws_security_group.h_k8s_worker[0].id
  source_security_group_id = aws_security_group.h_k8s_master[0].id
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  description              = "kubelet from master"
}

resource "aws_security_group_rule" "h_k8s_worker_nodeport_from_vpc" {
  count = var.create_h_k8s_nodes ? 1 : 0

  type              = "ingress"
  security_group_id = aws_security_group.h_k8s_worker[0].id
  cidr_blocks       = [local.net.vpc_cidr]
  from_port         = 30000
  to_port           = 32767
  protocol          = "tcp"
  description       = "NodePort from staging VPC"
}

resource "aws_security_group_rule" "h_k8s_worker_vxlan_from_vpc" {
  count = var.create_h_k8s_nodes ? 1 : 0

  type              = "ingress"
  security_group_id = aws_security_group.h_k8s_worker[0].id
  cidr_blocks       = [local.net.vpc_cidr]
  from_port         = 4789
  to_port           = 4789
  protocol          = "udp"
  description       = "Calico VXLAN from staging VPC"
}

resource "aws_security_group_rule" "h_k8s_worker_vxlan_self" {
  count = var.create_h_k8s_nodes ? 1 : 0

  type              = "ingress"
  security_group_id = aws_security_group.h_k8s_worker[0].id
  self              = true
  from_port         = 4789
  to_port           = 4789
  protocol          = "udp"
  description       = "Calico VXLAN between workers"
}
