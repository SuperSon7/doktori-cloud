# =============================================================================
# Dev App Layer — compute (dev-app + dev-ai 인스턴스)
# =============================================================================

data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.environment}/base/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  net = data.terraform_remote_state.base.outputs.networking
}

# -----------------------------------------------------------------------------
# Route53 — Internal DNS records
# -----------------------------------------------------------------------------
locals {
  dns_name_map = {
    dev_app = "app"
    dev_ai  = "ai"
  }
}

resource "aws_route53_record" "service" {
  for_each = local.dns_name_map

  zone_id = local.net.internal_zone_id
  name    = "${each.value}.${local.net.internal_zone_name}"
  type    = "A"
  ttl     = 300
  records = [module.compute.private_ips[each.key]]
}

module "compute" {
  source = "../../../modules/compute"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  vpc_id       = local.net.vpc_id
  vpc_cidr     = local.net.vpc_cidr
  subnet_ids   = local.net.subnet_ids
  key_name     = var.key_name

  s3_bucket_arns = [
    "arn:aws:s3:::${var.project_name}-v2-${var.environment}",
    "arn:aws:s3:::${var.project_name}-v2-dev",
  ]

  ssm_parameter_paths = [
    "/${var.project_name}/${var.environment}",
    "/${var.project_name}/dev",
  ]

  services = {
    dev_app = {
      instance_type = "t4g.medium"
      architecture  = "arm64"
      subnet_key    = "public"
      volume_size   = 60
      associate_eip = true
      tags = {
        Part        = "cloud"
        Environment = "dev"
        AutoStop    = "true"
      }
      sg_ingress = [
        { description = "HTTP", from_port = 80, to_port = 80, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "HTTPS", from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "Frontend from VPC", from_port = 3000, to_port = 3000, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "Backend from VPC", from_port = 8080, to_port = 8080, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "AI service from VPC", from_port = 8000, to_port = 8000, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "MySQL from VPC", from_port = 3306, to_port = 3306, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "SSH", from_port = 22, to_port = 22, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "MySQL from prod VPC", from_port = 3306, to_port = 3306, protocol = "tcp", cidr_blocks = ["10.1.0.0/16"] },
        { description = "RDS replication source", from_port = 3306, to_port = 3306, protocol = "tcp", cidr_blocks = ["15.164.45.30/32"] },
        { description = "Wiremock", from_port = 9090, to_port = 9090, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "RabbitMQ Management", from_port = 15672, to_port = 15672, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
      ]
    }
    dev_ai = {
      instance_type = "t4g.medium"
      architecture  = "arm64"
      subnet_key    = "public"
      volume_size   = 30
      tags = {
        Part        = "ai"
        Environment = "dev"
        AutoStop    = "true"
        Service     = "ai"
      }
      sg_ingress = [] # AI port(8000)는 dev_app SG에서 cross-rule로 허용
    }
  }

  sg_cross_rules = [
    { service_key = "dev_ai", source_key = "dev_app", from_port = 8000, to_port = 8000, protocol = "tcp" },
  ]
}
