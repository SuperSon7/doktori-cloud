# =============================================================================
# Dev Base Layer — networking + storage
# =============================================================================

# Ubuntu 24.04 ARM64 for NAT instance (dev uses Ubuntu, not Amazon Linux)
data "aws_ami" "nat_ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

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

  nat_ami_id        = data.aws_ami.nat_ubuntu.id
  nat_instance_type = "t4g.micro"
  nat_volume_size   = 10
  nat_key_name      = var.nat_key_name
  nat_user_data     = <<-USERDATA
    #!/bin/bash
    set -e

    # IP forwarding 활성화
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p

    # iptables MASQUERADE (아웃바운드 인터페이스 자동 감지)
    IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
    iptables -t nat -A POSTROUTING -o "$IFACE" -s 10.0.0.0/16 -j MASQUERADE

    # iptables 영속화
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
    netfilter-persistent save
  USERDATA

  nat_extra_tags = {
    Name     = "doktori-nonprod-nat-vpn"
    Service  = "nat-vpn"
    AutoStop = "false"
  }

  internal_domain = "dev.doktori.internal"

  # dev는 Interface Endpoint 미사용 (비용 절감 — NAT 경유로 AWS API 접근)
  vpc_interface_endpoints = []
}

# -----------------------------------------------------------------------------
# WireGuard VPN — dev NAT 인스턴스에서 VPN 서버 운용
# -----------------------------------------------------------------------------
resource "aws_security_group_rule" "nat_wireguard" {
  type              = "ingress"
  from_port         = 51820
  to_port           = 51820
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "WireGuard VPN"
  security_group_id = module.networking.nat_sg_id
}

# NOTE: storage module は Phase 2 で追加予定 (S3/ECR import 後)
# S3: doktori-v2-dev, ECR: doktori/backend-api 等は現在 Terraform 未管理
