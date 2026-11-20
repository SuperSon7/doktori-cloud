locals {
  net = var.networking
}

locals {
  mongo_db_name  = "doktoridb"
  mongo_username = "doktori"

  redis_ha_enabled    = var.enable_data_ha || var.enable_redis_ha
  rabbitmq_ha_enabled = var.enable_data_ha || var.enable_rabbitmq_ha
  mongodb_ha_enabled  = var.enable_mongodb_ha
  redis_node_order    = local.redis_ha_enabled ? ["a", "c", "b"] : ["a"]
  rabbitmq_node_order = local.rabbitmq_ha_enabled ? ["a", "c", "b"] : ["a"]
  mongodb_node_order  = local.mongodb_ha_enabled ? ["a", "c", "b"] : ["a"]
  all_data_az_nodes = {
    a = { subnet_key = "private_db_a", redis_role = "primary" }
    c = { subnet_key = "private_db_c", redis_role = "replica" }
    b = { subnet_key = "private_db_b", redis_role = "replica" }
  }
  # a 노드 키를 유지해 단일 노드에서 HA로 확장할 때 기존 EC2/SG/DNS 주소를 보존한다.
  redis_nodes = {
    for suffix in local.redis_node_order : (suffix == "a" ? "redis" : "redis_${suffix}") => merge(local.all_data_az_nodes[suffix], {
      node_name = "redis-${suffix}"
      dns_label = "redis-${suffix}"
    })
  }

  rabbitmq_nodes = {
    for suffix in local.rabbitmq_node_order : (suffix == "a" ? "rabbitmq" : "rabbitmq_${suffix}") => merge(local.all_data_az_nodes[suffix], {
      node_name = "rabbitmq-${suffix}"
      dns_label = "rabbitmq-${suffix}"
    })
  }

  mongodb_nodes = {
    for suffix in local.mongodb_node_order : (suffix == "a" ? "mongodb" : "mongodb_${suffix}") => merge(local.all_data_az_nodes[suffix], {
      node_name = suffix == "a" ? "mongodb" : "mongodb-${suffix}"
      dns_label = suffix == "a" ? "mongodb" : "mongodb-${suffix}"
      member_id = index(["a", "c", "b"], suffix)
    })
  }

  redis_service_keys    = keys(local.redis_nodes)
  rabbitmq_service_keys = keys(local.rabbitmq_nodes)
  mongodb_service_keys  = keys(local.mongodb_nodes)

  redis_sentinel_master = "doktori-master"
  redis_sentinel_nodes = [
    for suffix in local.redis_node_order :
    "redis-${suffix}.${local.net.internal_zone_name}:26379"
  ]
  rabbitmq_addresses = [
    for suffix in local.rabbitmq_node_order :
    "rabbitmq-${suffix}.${local.net.internal_zone_name}:5672"
  ]
  mongodb_hosts = [for key in local.mongodb_service_keys : "${local.mongodb_nodes[key].dns_label}.${local.net.internal_zone_name}:27017"]
  mongodb_members = [for key in local.mongodb_service_keys : {
    _id  = local.mongodb_nodes[key].member_id
    host = "${local.mongodb_nodes[key].dns_label}.${local.net.internal_zone_name}:27017"
  }]
  mongodb_uri_options = local.mongodb_ha_enabled ? "authSource=admin&replicaSet=${var.mongodb_replica_set_name}&w=majority&journal=true&retryWrites=true&wtimeoutMS=5000&serverSelectionTimeoutMS=10000" : "authSource=admin"

  app_client_cidrs = [
    local.net.subnet_cidrs["private_app"],
    local.net.subnet_cidrs["private_app_c"],
    local.net.subnet_cidrs["private_app_b"],
  ]
  # TODO: Replace app subnet CIDR rules with SG references once base provides
  # a shared data-client SG that app EC2/K8s workers can attach without creating
  # a data <-> app remote-state cycle.

  redis_node_cross_rules = local.redis_ha_enabled ? flatten([
    for pair in setproduct(local.redis_service_keys, local.redis_service_keys) : [
      { service_key = pair[0], source_key = pair[1], from_port = 6379, to_port = 6379, protocol = "tcp", description = "from peer Redis node SG to Redis data port" },
      { service_key = pair[0], source_key = pair[1], from_port = 26379, to_port = 26379, protocol = "tcp", description = "from peer Redis node SG to Redis Sentinel" },
    ] if pair[0] != pair[1]
  ]) : []

  rabbitmq_node_cross_rules = local.rabbitmq_ha_enabled ? flatten([
    for pair in setproduct(local.rabbitmq_service_keys, local.rabbitmq_service_keys) : [
      { service_key = pair[0], source_key = pair[1], from_port = 4369, to_port = 4369, protocol = "tcp", description = "from peer RabbitMQ node SG to epmd" },
      { service_key = pair[0], source_key = pair[1], from_port = 25672, to_port = 25672, protocol = "tcp", description = "from peer RabbitMQ node SG to cluster distribution" },
    ] if pair[0] != pair[1]
  ]) : []

  mongodb_node_cross_rules = local.mongodb_ha_enabled ? flatten([
    for pair in setproduct(local.mongodb_service_keys, local.mongodb_service_keys) : [
      { service_key = pair[0], source_key = pair[1], from_port = 27017, to_port = 27017, protocol = "tcp", description = "from peer MongoDB node SG to replica set member" },
    ] if pair[0] != pair[1]
  ]) : []
}
