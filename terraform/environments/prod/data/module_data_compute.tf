# =============================================================================
# Self-managed Data Services — Redis Sentinel + RabbitMQ quorum + MongoDB
# =============================================================================

module "data_compute" {
  source = "../../../modules/compute"

  name_suffix = "data"

  # Redis user_data reads SPRING_REDIS_PASSWORD from SSM at first boot.
  # This ensures the parameter exists before any EC2 in this module starts.
  depends_on = [
    aws_ssm_parameter.ha_monitor,
    aws_ssm_parameter.spring_redis_password,
    aws_ssm_parameter.mongo_replica_key,
    aws_ssm_parameter.mongo_admin_username,
    aws_ssm_parameter.mongo_admin_password,
    aws_ssm_parameter.mongo_username,
    aws_ssm_parameter.mongo_password,
  ]

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  vpc_id       = local.net.vpc_id
  vpc_cidr     = local.net.vpc_cidr
  subnet_ids   = local.net.subnet_ids
  key_name     = var.key_name

  s3_bucket_arns = [
    module.storage.bucket_arns["app"],
  ]

  ssm_parameter_paths = [
    "/${var.project_name}/${var.environment}",
  ]

  services = merge(
    {
      for service_key, node in local.redis_nodes : service_key => {
        instance_type = "t4g.micro"
        architecture  = "arm64"
        ami_id        = local.redis_ha_enabled ? var.ha_ami_ids["redis"] : var.redis_ami_id
        subnet_key    = node.subnet_key
        volume_size   = 20
        user_data = templatefile("${path.module}/templates/gzip_bootstrap.sh.tftpl", { payload = base64gzip(templatefile("${path.module}/templates/redis_node_user_data.sh.tftpl", {
          project_name                 = var.project_name
          environment                  = var.environment
          aws_region                   = var.aws_region
          node_name                    = node.node_name
          node_role                    = node.redis_role
          redis_sentinel_enabled       = local.redis_ha_enabled
          redis_master_name            = local.redis_sentinel_master
          redis_primary_dns            = "redis-a.${local.net.internal_zone_name}"
          redis_sentinel_quorum        = 2
          redis_sentinel_nodes         = join(",", local.redis_sentinel_nodes)
          allow_initial_primary        = var.allow_redis_initial_primary
          enable_data_ha_observability = var.enable_data_ha_observability && local.redis_ha_enabled
          remote_write_url             = var.data_ha_remote_write_url
          loki_push_url                = var.data_ha_loki_push_url
        })) })
        tags = { Owner = "data" }
        sg_ingress = concat(
          [
            { description = "from prod app subnets to Redis data port", from_port = 6379, to_port = 6379, protocol = "tcp", cidr_blocks = local.app_client_cidrs },
          ],
          local.redis_ha_enabled ? [
            { description = "from prod app subnets to Redis Sentinel", from_port = 26379, to_port = 26379, protocol = "tcp", cidr_blocks = local.app_client_cidrs },
          ] : []
        )
      }
    },
    {
      for service_key, node in local.rabbitmq_nodes : service_key => {
        instance_type = "t4g.micro"
        architecture  = "arm64"
        ami_id        = local.rabbitmq_ha_enabled ? var.ha_ami_ids["rabbitmq"] : var.rabbitmq_ami_id
        subnet_key    = node.subnet_key
        volume_size   = 20
        user_data = templatefile("${path.module}/templates/gzip_bootstrap.sh.tftpl", { payload = base64gzip(templatefile("${path.module}/templates/rabbitmq_node_user_data.sh.tftpl", {
          project_name                 = var.project_name
          environment                  = var.environment
          aws_region                   = var.aws_region
          node_name                    = node.node_name
          node_fqdn                    = "${node.dns_label}.${local.net.internal_zone_name}"
          cluster_enabled              = local.rabbitmq_ha_enabled
          primary_node_dns             = "rabbitmq-a.${local.net.internal_zone_name}"
          primary_nodename             = "rabbit@rabbitmq-a.${local.net.internal_zone_name}"
          enable_data_ha_observability = var.enable_data_ha_observability && local.rabbitmq_ha_enabled
          remote_write_url             = var.data_ha_remote_write_url
          loki_push_url                = var.data_ha_loki_push_url
          quorum_exporter_b64          = filebase64("${path.module}/../../../../scripts/data-ha/quorum_exporter.py")
        })) })
        tags = { Owner = "data" }
        sg_ingress = [
          { description = "from prod app subnets to RabbitMQ AMQP", from_port = 5672, to_port = 5672, protocol = "tcp", cidr_blocks = local.app_client_cidrs },
        ]
      }
    },
    {
      for service_key, node in local.mongodb_nodes : service_key => {
        instance_type = "t4g.micro"
        architecture  = "arm64"
        ami_id        = local.mongodb_ha_enabled ? var.ha_ami_ids["mongodb"] : var.mongodb_ami_id
        subnet_key    = node.subnet_key
        volume_size   = 20
        user_data = templatefile("${path.module}/templates/gzip_bootstrap.sh.tftpl", { payload = base64gzip(templatefile("${path.module}/templates/mongodb_node_user_data.sh.tftpl", {
          project_name                 = var.project_name
          environment                  = var.environment
          aws_region                   = var.aws_region
          node_name                    = node.node_name
          replica_enabled              = local.mongodb_ha_enabled
          replica_set_name             = var.mongodb_replica_set_name
          replica_member_id            = node.member_id
          replica_members_json         = jsonencode(local.mongodb_members)
          enable_data_ha_observability = var.enable_data_ha_observability && local.mongodb_ha_enabled
          remote_write_url             = var.data_ha_remote_write_url
          loki_push_url                = var.data_ha_loki_push_url
        })) })
        tags = { Owner = "data" }
        sg_ingress = [
          { description = "from prod app subnets to MongoDB", from_port = 27017, to_port = 27017, protocol = "tcp", cidr_blocks = local.app_client_cidrs },
        ]
      }
    },
  )

  sg_cross_rules = concat(
    local.redis_node_cross_rules,
    local.rabbitmq_node_cross_rules,
    local.mongodb_node_cross_rules,
  )
}
