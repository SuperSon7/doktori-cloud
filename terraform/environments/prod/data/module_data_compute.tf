# =============================================================================
# Self-managed Data Services — Redis Sentinel + RabbitMQ quorum + MongoDB
# =============================================================================

module "data_compute" {
  source = "../../../modules/compute"

  name_suffix = "data"

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
        ami_id        = var.redis_ami_id
        subnet_key    = node.subnet_key
        volume_size   = 20
        user_data = templatefile("${path.module}/templates/redis_node_user_data.sh.tftpl", {
          project_name           = var.project_name
          environment            = var.environment
          aws_region             = var.aws_region
          node_name              = node.node_name
          node_role              = node.redis_role
          redis_sentinel_enabled = var.enable_data_ha
          redis_master_name      = local.redis_sentinel_master
          redis_primary_dns      = "redis-a.${local.net.internal_zone_name}"
          redis_sentinel_quorum  = 2
        })
        tags = { Owner = "data" }
        sg_ingress = concat(
          [
            { description = "from prod app subnets to Redis data port", from_port = 6379, to_port = 6379, protocol = "tcp", cidr_blocks = local.app_client_cidrs },
          ],
          var.enable_data_ha ? [
            { description = "from prod app subnets to Redis Sentinel", from_port = 26379, to_port = 26379, protocol = "tcp", cidr_blocks = local.app_client_cidrs },
          ] : []
        )
      }
    },
    {
      for service_key, node in local.rabbitmq_nodes : service_key => {
        instance_type = "t4g.micro"
        architecture  = "arm64"
        ami_id        = var.rabbitmq_ami_id
        subnet_key    = node.subnet_key
        volume_size   = 20
        user_data = templatefile("${path.module}/templates/rabbitmq_node_user_data.sh.tftpl", {
          project_name     = var.project_name
          environment      = var.environment
          aws_region       = var.aws_region
          node_name        = node.node_name
          node_fqdn        = "${node.dns_label}.${local.net.internal_zone_name}"
          cluster_enabled  = var.enable_data_ha
          primary_node_dns = "rabbitmq-a.${local.net.internal_zone_name}"
          primary_nodename = "rabbit@rabbitmq-a.${local.net.internal_zone_name}"
        })
        tags = { Owner = "data" }
        sg_ingress = [
          { description = "from prod app subnets to RabbitMQ AMQP", from_port = 5672, to_port = 5672, protocol = "tcp", cidr_blocks = local.app_client_cidrs },
        ]
      }
    },
    {
      mongodb = {
        instance_type = "t4g.micro"
        architecture  = "arm64"
        ami_id        = var.mongodb_ami_id
        subnet_key    = "private_db_a"
        volume_size   = 20
        user_data = templatefile("${path.module}/templates/mongodb_node_user_data.sh.tftpl", {
          project_name = var.project_name
          environment  = var.environment
          aws_region   = var.aws_region
          node_name    = "mongodb"
        })
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
  )
}
