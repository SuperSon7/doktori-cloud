module "networking" {
  source = "../../../modules/networking"

  project_name      = var.project_name
  environment       = var.environment
  aws_region        = var.aws_region
  vpc_cidr          = "10.0.0.0/16"
  availability_zone = "ap-northeast-2a"

  subnets = {
    public      = { cidr = "10.0.0.0/22", tier = "public", az_key = "primary" }
    private_app = { cidr = "10.0.16.0/20", tier = "private-app", az_key = "primary" }
    private_db  = { cidr = "10.0.32.0/24", tier = "private-db", az_key = "primary" }
  }

  nat_ami_id        = data.aws_ami.nat_golden.id
  nat_instance_type = "t4g.micro"
  nat_volume_size   = 10
  # nat_key_name 미설정 — SSM Session Manager로 접근 (NAT는 public 서브넷, IGW 통해 SSM 접근 가능)

  nat_extra_tags = {
    Name     = "${var.project_name}-${var.environment}-nat"
    Service  = "nat"
    AutoStop = "false"
    Owner    = "cloud"
  }

  internal_domain = "${var.environment}.doktori.internal"

  # dev는 Interface Endpoint 미사용 (비용 절감 — NAT 경유로 AWS API 접근)
  vpc_interface_endpoints = []
}
