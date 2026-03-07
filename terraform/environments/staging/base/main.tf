# =============================================================================
# Staging Base Layer — networking (no VPC endpoints for cost savings)
# =============================================================================

module "networking" {
  source = "../../../modules/networking"

  project_name                = var.project_name
  environment                 = var.environment
  aws_region                  = var.aws_region
  vpc_cidr                    = "10.2.0.0/16"
  availability_zone           = "ap-northeast-2a"
  secondary_availability_zone = "ap-northeast-2c"

  subnets = {
    public      = { cidr = "10.2.0.0/22", tier = "public", az_key = "primary" }
    private_app = { cidr = "10.2.16.0/20", tier = "private-app", az_key = "primary" }
    private_db  = { cidr = "10.2.32.0/24", tier = "private-db", az_key = "primary" }
    private_rds = { cidr = "10.2.40.0/24", tier = "private-db", az_key = "secondary" }
  }

  # No VPC endpoints — routes through NAT (saves ~$60/month)
  vpc_interface_endpoints = []
}
