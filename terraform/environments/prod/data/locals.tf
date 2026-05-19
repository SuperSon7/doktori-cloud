locals {
  net = {
    vpc_id   = data.terraform_remote_state.base.outputs.networking.vpc_id
    vpc_cidr = data.terraform_remote_state.base.outputs.networking.vpc_cidr
    subnet_ids = {
      private_db_a = data.terraform_remote_state.base.outputs.networking.subnet_ids["private_db_a"]
      private_db_c = data.terraform_remote_state.base.outputs.networking.subnet_ids["private_db_c"]
      private_db_b = data.terraform_remote_state.base.outputs.networking.subnet_ids["private_db_b"]
    }
    subnet_cidrs       = data.terraform_remote_state.base.outputs.networking.subnet_cidrs
    internal_zone_id   = data.terraform_remote_state.base.outputs.networking.internal_zone_id
    internal_zone_name = data.terraform_remote_state.base.outputs.networking.internal_zone_name
  }
}

locals {
  mongo_db_name  = "doktoridb"
  mongo_username = "doktori"

  data_node_order = var.enable_data_ha ? ["a", "c", "b"] : ["a"]
  all_data_az_nodes = {
    a = { subnet_key = "private_db_a", redis_role = "primary" }
    c = { subnet_key = "private_db_c", redis_role = "replica" }
    b = { subnet_key = "private_db_b", redis_role = "replica" }
  }
  data_az_nodes = {
    for suffix, node in local.all_data_az_nodes : suffix => node
    if contains(local.data_node_order, suffix)
  }

  redis_nodes = var.enable_data_ha ? {
    for suffix, node in local.data_az_nodes : "redis_${suffix}" => merge(node, {
      node_name = "redis-${suffix}"
      dns_label = "redis-${suffix}"
    })
    } : {
    redis = merge(local.all_data_az_nodes.a, {
      node_name = "redis-a"
      dns_label = "redis-a"
    })
  }

  rabbitmq_nodes = var.enable_data_ha ? {
    for suffix, node in local.data_az_nodes : "rabbitmq_${suffix}" => merge(node, {
      node_name = "rabbitmq-${suffix}"
      dns_label = "rabbitmq-${suffix}"
    })
    } : {
    rabbitmq = merge(local.all_data_az_nodes.a, {
      node_name = "rabbitmq-a"
      dns_label = "rabbitmq-a"
    })
  }

  redis_service_keys    = keys(local.redis_nodes)
  rabbitmq_service_keys = keys(local.rabbitmq_nodes)

  redis_sentinel_master = "doktori-master"
  redis_sentinel_nodes = [
    for suffix in local.data_node_order :
    "redis-${suffix}.${local.net.internal_zone_name}:26379"
  ]
  rabbitmq_addresses = [
    for suffix in local.data_node_order :
    "rabbitmq-${suffix}.${local.net.internal_zone_name}:5672"
  ]

  app_client_cidrs = [
    local.net.subnet_cidrs["private_app"],
    local.net.subnet_cidrs["private_app_c"],
    local.net.subnet_cidrs["private_app_b"],
  ]
  # TODO: Replace app subnet CIDR rules with SG references once base provides
  # a shared data-client SG that app EC2/K8s workers can attach without creating
  # a data <-> app remote-state cycle.

  redis_node_cross_rules = var.enable_data_ha ? flatten([
    for pair in setproduct(local.redis_service_keys, local.redis_service_keys) : [
      { service_key = pair[0], source_key = pair[1], from_port = 6379, to_port = 6379, protocol = "tcp", description = "from peer Redis node SG to Redis data port" },
      { service_key = pair[0], source_key = pair[1], from_port = 26379, to_port = 26379, protocol = "tcp", description = "from peer Redis node SG to Redis Sentinel" },
    ] if pair[0] != pair[1]
  ]) : []

  rabbitmq_node_cross_rules = var.enable_data_ha ? flatten([
    for pair in setproduct(local.rabbitmq_service_keys, local.rabbitmq_service_keys) : [
      { service_key = pair[0], source_key = pair[1], from_port = 4369, to_port = 4369, protocol = "tcp", description = "from peer RabbitMQ node SG to epmd" },
      { service_key = pair[0], source_key = pair[1], from_port = 25672, to_port = 25672, protocol = "tcp", description = "from peer RabbitMQ node SG to cluster distribution" },
    ] if pair[0] != pair[1]
  ]) : []
}

# =============================================================================
# CodeDeploy Revision Bucket — stateful, app 레이어에서 이동
# =============================================================================
locals {
  codedeploy_revision_bucket_name = "${var.project_name}-${var.environment}-frontend-codedeploy-revisions-${data.aws_caller_identity.current.account_id}"
}

locals {
  data_dns_name_map = merge(
    { for service_key, node in local.redis_nodes : service_key => node.dns_label },
    { for service_key, node in local.rabbitmq_nodes : service_key => node.dns_label },
    { mongodb = "mongodb" },
  )
}
