# =============================================================================
# Prod Base Layer — networking + storage
# =============================================================================

module "networking" {
  source = "../../../modules/networking"

  project_name                = var.project_name
  environment                 = var.environment
  aws_region                  = var.aws_region
  vpc_cidr                    = "10.1.0.0/16"
  availability_zone           = "ap-northeast-2a"
  secondary_availability_zone = "ap-northeast-2c"
  tertiary_availability_zone  = "ap-northeast-2b"

  subnets = {
    public        = { cidr = "10.1.0.0/22", tier = "public", az_key = "primary" }
    public_c      = { cidr = "10.1.4.0/22", tier = "public", az_key = "secondary" }
    public_b      = { cidr = "10.1.8.0/22", tier = "public", az_key = "tertiary" }
    private_app   = { cidr = "10.1.16.0/20", tier = "private-app", az_key = "primary" }
    private_app_c = { cidr = "10.1.48.0/20", tier = "private-app", az_key = "secondary" }
    private_app_b = { cidr = "10.1.64.0/20", tier = "private-app", az_key = "tertiary" }
    private_db    = { cidr = "10.1.32.0/24", tier = "private-db", az_key = "primary" }
    private_rds   = { cidr = "10.1.40.0/24", tier = "private-db", az_key = "secondary" }
  }

  nat_instances = {
    primary   = { subnet_key = "public" }
    secondary = { subnet_key = "public_c" }
  }

  internal_domain = "${var.environment}.doktori.internal"

  vpc_interface_endpoints = ["ssm", "ssmmessages", "ec2messages", "ecr.api", "ecr.dkr", "logs"]
  vpc_endpoint_subnet_key = "private_app"
}

# -----------------------------------------------------------------------------
# Storage — S3 buckets
# -----------------------------------------------------------------------------
module "storage" {
  source = "../../../modules/storage"

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = var.aws_region
  create_kms_and_iam = true

  s3_buckets = {
    app = {
      bucket_name        = "doktori-v2-prod"
      public_read        = true
      public_read_prefix = "/images/*"
      versioning         = true
      enable_cors        = true
      encryption         = true
      bucket_key_enabled = true
      folders = [
        "backup/",
        "images/meetings/",
        "images/profiles/",
        "images/reviews/",
      ]
    }
  }
}

# -----------------------------------------------------------------------------
# SSM Parameter Store
# -----------------------------------------------------------------------------
module "ssm_parameters" {
  source = "../../../modules/ssm-parameters"

  project_name = var.project_name
  environment  = var.environment

  # prod 전용 파라미터 (공통 파라미터는 모듈 default로 포함)
  extra_parameters = {
    "DB_URL"                        = { type = "SecureString" }  # dev는 String
    "RUNPOD_POLL_TIMEOUT_SECONDS"   = { type = "SecureString" }  # dev는 String
    "NEXT_PUBLIC_API_BASE_URL_PROD" = { type = "String" }
    "NEXT_PUBLIC_CHAT_BASE_URL_PROD" = { type = "String" }
  }
}

# =============================================================================
# VPC Peering — prod ↔ mgmt (monitoring)
# =============================================================================
data "terraform_remote_state" "monitoring" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "monitoring/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  mgmt_vpc_id   = data.terraform_remote_state.monitoring.outputs.mgmt_vpc_id
  mgmt_vpc_cidr = data.terraform_remote_state.monitoring.outputs.mgmt_vpc_cidr
  mgmt_zone_id  = data.terraform_remote_state.monitoring.outputs.mgmt_zone_id
}

resource "aws_vpc_peering_connection" "prod_to_mgmt" {
  vpc_id      = module.networking.vpc_id
  peer_vpc_id = local.mgmt_vpc_id
  auto_accept = true

  tags = { Name = "${var.project_name}-${var.environment}-to-mgmt" }
}

# --- prod → mgmt routes ---
# public route table
resource "aws_route" "prod_public_to_mgmt" {
  route_table_id            = module.networking.public_route_table_id
  destination_cidr_block    = local.mgmt_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.prod_to_mgmt.id
}

# private route tables (all AZs)
resource "aws_route" "prod_private_to_mgmt" {
  for_each = module.networking.private_route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = local.mgmt_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.prod_to_mgmt.id
}

# --- mgmt → prod route (default VPC main route table) ---
data "aws_route_table" "mgmt_main" {
  vpc_id = local.mgmt_vpc_id

  filter {
    name   = "association.main"
    values = ["true"]
  }
}

resource "aws_route" "mgmt_to_prod" {
  route_table_id            = data.aws_route_table.mgmt_main.id
  destination_cidr_block    = "10.1.0.0/16"
  vpc_peering_connection_id = aws_vpc_peering_connection.prod_to_mgmt.id
}

# --- mgmt PHZ → prod VPC association (monitoring.mgmt.doktori.internal resolve) ---
resource "aws_route53_zone_association" "mgmt_phz_prod" {
  zone_id = local.mgmt_zone_id
  vpc_id  = module.networking.vpc_id
}
