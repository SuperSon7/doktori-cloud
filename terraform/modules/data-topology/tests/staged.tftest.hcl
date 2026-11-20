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

run "second_stage_keeps_redis" {
  command = plan
  variables {
    enable_redis_ha    = true
    enable_rabbitmq_ha = true
  }
  assert {
    condition     = length(local.redis_nodes) == 3 && length(local.rabbitmq_nodes) == 3 && length(local.mongodb_nodes) == 1
    error_message = "Stage 2 must keep Redis HA and leave MongoDB single-node."
  }
  assert {
    condition     = alltrue([for nodes in [local.redis_nodes, local.rabbitmq_nodes] : length(distinct([for node in values(nodes) : node.subnet_key])) == 3])
    error_message = "Redis and RabbitMQ must each span three AZ subnet keys."
  }
}
