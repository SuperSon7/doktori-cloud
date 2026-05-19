locals {
  net = {
    vpc_id   = data.aws_vpc.main.id
    vpc_cidr = data.aws_vpc.main.cidr_block
    subnet_ids = {
      public        = data.aws_subnet.public.id
      private_app   = data.aws_subnet.private_app.id
      private_db    = data.aws_subnet.private_db.id
      private_rds   = data.aws_subnet.private_rds.id
      private_k8s_a = data.aws_subnet.private_k8s_a.id
      private_k8s_b = data.aws_subnet.private_k8s_b.id
    }
    internal_zone_id   = data.aws_route53_zone.internal.zone_id
    internal_zone_name = data.aws_route53_zone.internal.name
    private_route_table_ids = {
      primary = data.aws_route_table.private_primary.id
    }
  }
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
