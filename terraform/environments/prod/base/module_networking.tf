module "networking" {
  source = "../../../modules/networking"

  project_name                = var.project_name
  environment                 = var.environment
  aws_region                  = var.aws_region
  vpc_cidr                    = local.vpc_cidr
  availability_zone           = local.az_primary
  secondary_availability_zone = local.az_secondary
  tertiary_availability_zone  = local.az_tertiary

  subnets = {
    public        = { cidr = "10.1.0.0/22", tier = "public", az_key = "primary" }
    public_c      = { cidr = "10.1.4.0/22", tier = "public", az_key = "secondary" }
    public_b      = { cidr = "10.1.8.0/22", tier = "public", az_key = "tertiary" }
    private_app   = { cidr = "10.1.16.0/20", tier = "private-app", az_key = "primary" }
    private_app_c = { cidr = "10.1.48.0/20", tier = "private-app", az_key = "secondary" }
    private_app_b = { cidr = "10.1.64.0/20", tier = "private-app", az_key = "tertiary" }
    private_db_a  = { cidr = "10.1.32.0/24", tier = "private-db", az_key = "primary" }
    private_db_c  = { cidr = "10.1.40.0/24", tier = "private-db", az_key = "secondary" }
    private_db_b  = { cidr = "10.1.41.0/24", tier = "private-db", az_key = "tertiary" }
  }

  nat_instances = {
    primary   = { subnet_key = "public" }
    secondary = { subnet_key = "public_c" }
    tertiary  = { subnet_key = "public_b" }
  }
  nat_ami_id = data.aws_ami.nat_golden.id

  internal_domain = "${var.environment}.doktori.internal"

  # 비용 절감: 당장 상시 운영 전까지 Interface Endpoint는 만들지 않는다.
  # SSM/ECR/Logs가 NAT 없이 필요해지면 ["ssm", "ssmmessages", "ec2messages", "ecr.api", "ecr.dkr", "logs"]를 복구한다.
  vpc_interface_endpoints = []
  vpc_endpoint_subnet_key = "private_app"
}
