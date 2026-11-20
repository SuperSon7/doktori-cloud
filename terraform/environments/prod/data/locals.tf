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
  mongo_db_name             = module.data_topology.config.mongo_db_name
  mongo_username            = module.data_topology.config.mongo_username
  redis_ha_enabled          = module.data_topology.config.redis_ha_enabled
  rabbitmq_ha_enabled       = module.data_topology.config.rabbitmq_ha_enabled
  mongodb_ha_enabled        = module.data_topology.config.mongodb_ha_enabled
  redis_nodes               = module.data_topology.config.redis_nodes
  rabbitmq_nodes            = module.data_topology.config.rabbitmq_nodes
  mongodb_nodes             = module.data_topology.config.mongodb_nodes
  redis_service_keys        = module.data_topology.config.redis_service_keys
  rabbitmq_service_keys     = module.data_topology.config.rabbitmq_service_keys
  mongodb_service_keys      = module.data_topology.config.mongodb_service_keys
  redis_sentinel_master     = module.data_topology.config.redis_sentinel_master
  redis_sentinel_nodes      = module.data_topology.config.redis_sentinel_nodes
  rabbitmq_addresses        = module.data_topology.config.rabbitmq_addresses
  mongodb_hosts             = module.data_topology.config.mongodb_hosts
  mongodb_members           = module.data_topology.config.mongodb_members
  mongodb_uri_options       = module.data_topology.config.mongodb_uri_options
  app_client_cidrs          = module.data_topology.config.app_client_cidrs
  redis_node_cross_rules    = module.data_topology.config.redis_node_cross_rules
  rabbitmq_node_cross_rules = module.data_topology.config.rabbitmq_node_cross_rules
  mongodb_node_cross_rules  = module.data_topology.config.mongodb_node_cross_rules
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
    { for service_key, node in local.mongodb_nodes : service_key => node.dns_label },
  )
}
