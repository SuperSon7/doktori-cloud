# =============================================================================
# Staging App Layer — compute (downsized instances for cost savings)
# =============================================================================

data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.environment}/base/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  net = data.terraform_remote_state.base.outputs.networking
}

data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_iam_instance_profile" "staging_ec2_ssm" {
  name = "${var.project_name}-${var.environment}-ec2-ssm"
}


# -----------------------------------------------------------------------------
# Route53 — Internal DNS records
# -----------------------------------------------------------------------------
locals {
  dns_name_map = {
    nginx          = "nginx"
    front          = "front"
    api            = "api"
    chat           = "chat"
    ai             = "ai"
    rds_monitoring = "rds-exporter"
    redis          = "redis"
    rabbitmq       = "rabbitmq"
  }
}

resource "aws_route53_record" "service" {
  for_each = local.dns_name_map

  zone_id = local.net.internal_zone_id
  name    = "${each.value}.${local.net.internal_zone_name}"
  type    = "A"
  ttl     = 300
  records = [module.compute.private_ips[each.key]]
}

module "compute" {
  source = "../../../modules/compute"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  vpc_id       = local.net.vpc_id
  vpc_cidr     = local.net.vpc_cidr
  subnet_ids   = local.net.subnet_ids
  key_name     = var.key_name

  s3_bucket_arns = [
    "arn:aws:s3:::${var.project_name}-v2-${var.environment}",
  ]

  ssm_parameter_paths = [
    "/${var.project_name}/${var.environment}",
  ]

  services = {
    nginx = {
      instance_type = var.instance_types["nginx"]
      architecture  = "arm64"
      subnet_key    = "public"
      volume_size   = var.default_volume_size
      associate_eip = true
      tags          = { Part = "cloud" }
      sg_ingress = [
        { description = "HTTP from anywhere", from_port = 80, to_port = 80, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "HTTPS from anywhere", from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
      ]
    }
    front = {
      instance_type = var.instance_types["front"]
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = var.default_volume_size
      tags          = { Part = "fe" }
      sg_ingress    = []
    }
    api = {
      instance_type = var.instance_types["api"]
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = var.default_volume_size
      tags          = { Part = "be" }
      sg_ingress    = []
    }
    chat = {
      instance_type = var.instance_types["chat"]
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = var.default_volume_size
      tags          = { Part = "be" }
      sg_ingress    = []
    }
    ai = {
      instance_type = var.instance_types["ai"]
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = var.default_volume_size
      tags          = { Part = "ai" }
      sg_ingress    = []
    }
    rds_monitoring = {
      instance_type = var.instance_types["rds_monitoring"]
      architecture  = "x86"
      subnet_key    = "public"
      volume_size   = var.default_volume_size
      tags          = { Part = "monitoring" }
      sg_ingress = [
        { description = "MySQL exporter from VPC", from_port = 9104, to_port = 9104, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
      ]
    }
    redis = {
      instance_type = var.instance_types["redis"]
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = var.default_volume_size
      tags          = { Part = "data" }
      sg_ingress = [
        { description = "Redis from VPC", from_port = 6379, to_port = 6379, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
      ]
    }
    rabbitmq = {
      instance_type = var.instance_types["rabbitmq"]
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = var.default_volume_size
      tags          = { Part = "data" }
      sg_ingress = [
        { description = "RabbitMQ AMQP from VPC", from_port = 5672, to_port = 5672, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "RabbitMQ mgmt from VPC", from_port = 15672, to_port = 15672, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
      ]
    }
  }

  sg_cross_rules = [
    { service_key = "front", source_key = "nginx", from_port = 3000, to_port = 3001, protocol = "tcp" },
    { service_key = "api", source_key = "nginx", from_port = 8080, to_port = 8082, protocol = "tcp" },
    { service_key = "chat", source_key = "nginx", from_port = 8081, to_port = 8083, protocol = "tcp" },
    { service_key = "ai", source_key = "nginx", from_port = 8000, to_port = 8000, protocol = "tcp" },
  ]
}

locals {
  h_k8s_nodes = var.create_h_k8s_nodes ? {
    "h-k8s-master" = {
      instance_type = var.h_k8s_instance_types["master"]
      volume_size   = var.h_k8s_volume_sizes["master"]
      role          = "k8s-cp"
      security_role = "master"
      subnet_key    = "private_k8s_a"
    }
    "h-k8s-worker-1" = {
      instance_type = var.h_k8s_instance_types["worker_1"]
      volume_size   = var.h_k8s_volume_sizes["worker_1"]
      role          = "k8s-worker"
      security_role = "worker"
      subnet_key    = "private_k8s_a"
    }
    "h-k8s-worker-2" = {
      instance_type = var.h_k8s_instance_types["worker_2"]
      volume_size   = var.h_k8s_volume_sizes["worker_2"]
      role          = "k8s-worker"
      security_role = "worker"
      subnet_key    = "private_k8s_b"
    }
  } : {}
}

resource "aws_subnet" "h_k8s" {
  for_each = var.create_h_k8s_nodes ? {
    private_k8s_a = {
      cidr = "10.2.48.0/24"
      az   = "ap-northeast-2a"
    }
    private_k8s_b = {
      cidr = "10.2.49.0/24"
      az   = "ap-northeast-2b"
    }
  } : {}

  vpc_id                  = local.net.vpc_id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}"
    Tier = "private-k8s"
  }
}

resource "aws_route_table_association" "h_k8s" {
  for_each = aws_subnet.h_k8s

  subnet_id      = each.value.id
  route_table_id = local.net.private_route_table_ids["primary"]
}

resource "aws_security_group" "h_k8s_master" {
  count = var.create_h_k8s_nodes ? 1 : 0

  name_prefix = "${var.project_name}-${var.environment}-h-k8s-master-"
  description = "Security group for h-k8s master"
  vpc_id      = local.net.vpc_id

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "h-k8s-master-sg"
    Role = "k8s-cp"
  }
}

resource "aws_security_group" "h_k8s_worker" {
  count = var.create_h_k8s_nodes ? 1 : 0

  name_prefix = "${var.project_name}-${var.environment}-h-k8s-worker-"
  description = "Security group for h-k8s workers"
  vpc_id      = local.net.vpc_id

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "h-k8s-worker-sg"
    Role = "k8s-worker"
  }
}

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

resource "aws_instance" "h_k8s" {
  for_each = local.h_k8s_nodes

  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = each.value.instance_type
  key_name               = null
  subnet_id              = aws_subnet.h_k8s[each.value.subnet_key].id
  vpc_security_group_ids = each.value.security_role == "master" ? [aws_security_group.h_k8s_master[0].id] : [aws_security_group.h_k8s_worker[0].id]
  iam_instance_profile   = data.aws_iam_instance_profile.staging_ec2_ssm.name

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = each.value.volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = each.key
    env  = var.environment
    role = each.value.role
  }

  depends_on = [aws_route_table_association.h_k8s]
}
