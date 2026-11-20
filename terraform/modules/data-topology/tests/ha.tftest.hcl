variables {
  networking = {
    internal_zone_name = "prod.doktori.internal"
    subnet_cidrs = {
      private_app   = "10.1.10.0/24"
      private_app_c = "10.1.11.0/24"
      private_app_b = "10.1.12.0/24"
    }
  }
}

run "single_node_defaults" {
  command = plan
  assert {
    condition     = length(local.redis_nodes) == 1 && length(local.rabbitmq_nodes) == 1 && length(local.mongodb_nodes) == 1
    error_message = "Default must preserve the three existing single-node services."
  }
  assert {
    condition     = contains(keys(local.redis_nodes), "redis") && contains(keys(local.rabbitmq_nodes), "rabbitmq") && contains(keys(local.mongodb_nodes), "mongodb")
    error_message = "Existing primary resource addresses must remain stable."
  }
}

run "redis_only" {
  command = plan
  variables { enable_redis_ha = true }
  assert {
    condition     = length(local.redis_nodes) == 3 && length(local.rabbitmq_nodes) == 1 && length(local.mongodb_nodes) == 1
    error_message = "Redis HA must not change the other services."
  }
  assert {
    condition     = length(local.redis_sentinel_nodes) == 3 && length(local.redis_node_cross_rules) == 12
    error_message = "Sentinel discovery and peer connectivity must be present."
  }
}

run "rabbitmq_only" {
  command = plan
  variables { enable_rabbitmq_ha = true }
  assert {
    condition     = length(local.rabbitmq_nodes) == 3 && length(local.redis_nodes) == 1 && length(local.mongodb_nodes) == 1
    error_message = "RabbitMQ HA must be independently selectable."
  }
}

run "mongodb_only" {
  command = plan
  variables { enable_mongodb_ha = true }
  assert {
    condition     = length(local.mongodb_nodes) == 3 && length(local.mongodb_node_cross_rules) == 6
    error_message = "MongoDB needs three data members with peer connections."
  }
  assert {
    condition     = length(distinct([for node in values(local.mongodb_nodes) : node.subnet_key])) == 3
    error_message = "MongoDB members must span three AZ subnets."
  }
  assert {
    condition     = strcontains(local.mongodb_uri_options, "replicaSet=doktori-rs") && strcontains(local.mongodb_uri_options, "w=majority")
    error_message = "Client discovery and majority write concern must be configured together."
  }
}

run "all_services" {
  command = plan
  variables {
    enable_redis_ha    = true
    enable_rabbitmq_ha = true
    enable_mongodb_ha  = true
  }
  assert {
    condition     = length(local.redis_nodes) + length(local.rabbitmq_nodes) + length(local.mongodb_nodes) == 9 && contains(keys(local.redis_nodes), "redis") && contains(keys(local.rabbitmq_nodes), "rabbitmq") && contains(keys(local.mongodb_nodes), "mongodb")
    error_message = "Full HA must add six nodes while keeping all original primary keys."
  }
}

run "legacy_switch" {
  command = plan
  variables { enable_data_ha = true }
  assert {
    condition     = length(local.redis_nodes) == 3 && length(local.rabbitmq_nodes) == 3 && length(local.mongodb_nodes) == 1
    error_message = "Legacy switch must retain its original Redis/RabbitMQ scope."
  }
}
