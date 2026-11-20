locals {
  ha_monitor_parameters = {
    for service, enabled in { rabbitmq = local.rabbitmq_ha_enabled, mongodb = local.mongodb_ha_enabled } :
    service => (service == "rabbitmq" ? "RABBITMQ_MONITOR_PASSWORD" : "MONGO_MONITOR_PASSWORD")
    if var.enable_data_ha_observability && enabled
  }
}

ephemeral "random_password" "ha_monitor" {
  for_each = toset(keys(local.ha_monitor_parameters))
  length   = 32
  special  = false
}

resource "aws_ssm_parameter" "ha_monitor" {
  for_each         = local.ha_monitor_parameters
  name             = "/${var.project_name}/${var.environment}/${each.value}"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.ha_monitor[each.key].result
  value_wo_version = 1
  tags             = { Owner = "data-ha-observability" }
}

output "data_ha_observability_inventory" {
  description = "Non-secret render input; export only when authorized to access the actual backend/state."
  value = {
    env     = var.environment
    cluster = "${var.project_name}-${var.environment}-data"
    targets = var.enable_data_ha_observability ? concat(
      local.redis_ha_enabled ? flatten([for node in values(local.redis_nodes) : [
        { service = "redis", job = "redis", node = node.node_name },
        { service = "redis", job = "redis-sentinel", node = node.node_name },
      ]]) : [],
      local.rabbitmq_ha_enabled ? flatten([for node in values(local.rabbitmq_nodes) : [
        { service = "rabbitmq", job = "rabbitmq", node = node.node_name },
        { service = "rabbitmq", job = "rabbitmq-quorum", node = node.node_name },
      ]]) : [],
      local.mongodb_ha_enabled ? [for node in values(local.mongodb_nodes) :
        { service = "mongodb", job = "mongodb", node = node.node_name }
      ] : [],
      local.redis_ha_enabled ? [for node in values(local.redis_nodes) :
        { service = "redis", job = "data-ha-alloy", node = node.node_name }
      ] : [],
      local.rabbitmq_ha_enabled ? [for node in values(local.rabbitmq_nodes) :
        { service = "rabbitmq", job = "data-ha-alloy", node = node.node_name }
      ] : [],
      local.mongodb_ha_enabled ? [for node in values(local.mongodb_nodes) :
        { service = "mongodb", job = "data-ha-alloy", node = node.node_name }
      ] : [],
    ) : []
  }
}
