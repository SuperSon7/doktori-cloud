# =============================================================================
# Staging App Layer — compute (downsized instances for cost savings)
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
  ]

  ssm_parameter_paths = [
    "/${var.project_name}/${var.environment}",
  ]

  services = {
    nginx = {
      instance_type = var.instance_types["nginx"]
      architecture  = "arm64"
      subnet_key    = "public"
      volume_size   = var.default_volume_size
      associate_eip = true
      tags          = { Part = "cloud" }
      sg_ingress = [
        { description = "HTTP from anywhere", from_port = 80, to_port = 80, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "HTTPS from anywhere", from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
      ]
    }
    front = {
      instance_type = var.instance_types["front"]
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = var.default_volume_size
      tags          = { Part = "fe" }
      sg_ingress    = []
    }
    api = {
      instance_type = var.instance_types["api"]
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = var.default_volume_size
      tags          = { Part = "be" }
      sg_ingress    = []
    }
    chat = {
      instance_type = var.instance_types["chat"]
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = var.default_volume_size
      tags          = { Part = "be" }
      sg_ingress    = []
    }
    ai = {
      instance_type = var.instance_types["ai"]
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = var.default_volume_size
      tags          = { Part = "ai" }
      sg_ingress    = []
    }
    rds_monitoring = {
      instance_type = var.instance_types["rds_monitoring"]
      architecture  = "x86"
      subnet_key    = "public"
      volume_size   = var.default_volume_size
      tags          = { Part = "monitoring" }
      sg_ingress = [
        { description = "MySQL exporter from VPC", from_port = 9104, to_port = 9104, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
      ]
    }
  }

  sg_cross_rules = [
    { service_key = "front", source_key = "nginx", from_port = 3000, to_port = 3001, protocol = "tcp" },
    { service_key = "api", source_key = "nginx", from_port = 8080, to_port = 8082, protocol = "tcp" },
    { service_key = "chat", source_key = "nginx", from_port = 8081, to_port = 8083, protocol = "tcp" },
    { service_key = "ai", source_key = "nginx", from_port = 8000, to_port = 8000, protocol = "tcp" },
  ]
}
