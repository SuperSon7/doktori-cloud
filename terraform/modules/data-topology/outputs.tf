output "config" {
  value = {
    mongo_db_name             = local.mongo_db_name
    mongo_username            = local.mongo_username
    redis_ha_enabled          = local.redis_ha_enabled
    rabbitmq_ha_enabled       = local.rabbitmq_ha_enabled
    mongodb_ha_enabled        = local.mongodb_ha_enabled
    redis_nodes               = local.redis_nodes
    rabbitmq_nodes            = local.rabbitmq_nodes
    mongodb_nodes             = local.mongodb_nodes
    redis_service_keys        = local.redis_service_keys
    rabbitmq_service_keys     = local.rabbitmq_service_keys
    mongodb_service_keys      = local.mongodb_service_keys
    redis_sentinel_master     = local.redis_sentinel_master
    redis_sentinel_nodes      = local.redis_sentinel_nodes
    rabbitmq_addresses        = local.rabbitmq_addresses
    mongodb_hosts             = local.mongodb_hosts
    mongodb_members           = local.mongodb_members
    mongodb_uri_options       = local.mongodb_uri_options
    app_client_cidrs          = local.app_client_cidrs
    redis_node_cross_rules    = local.redis_node_cross_rules
    rabbitmq_node_cross_rules = local.rabbitmq_node_cross_rules
    mongodb_node_cross_rules  = local.mongodb_node_cross_rules
  }
}
