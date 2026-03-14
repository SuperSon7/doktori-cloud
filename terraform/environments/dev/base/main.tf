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
    Name     = "doktori-dev-nat-vpn"
    Service  = "nat-vpn"
    AutoStop = "false"
  }

  internal_domain = "dev.doktori.internal"

  # dev는 Interface Endpoint 미사용 (비용 절감 — NAT 경유로 AWS API 접근)
  vpc_interface_endpoints = []

  # WireGuard VPN — dev NAT 인스턴스에서 VPN 서버 운용
  nat_extra_ingress = [
    { description = "WireGuard VPN", from_port = 51820, to_port = 51820, protocol = "udp", cidr_blocks = ["0.0.0.0/0"] },
  ]
}

# -----------------------------------------------------------------------------
# Storage — S3 buckets
# -----------------------------------------------------------------------------
module "storage" {
  source = "../../../modules/storage"

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = var.aws_region
  create_kms_and_iam = false # 기존 수동 생성 KMS/IAM 유지 — Phase 1에서 import 예정

  s3_buckets = {
    app = {
      bucket_name        = "doktori-v2-dev"
      public_read        = true
      public_read_prefix = "/images/*"
      versioning         = false
      enable_cors        = true
      encryption         = true
      bucket_key_enabled = true
      folders = [
        "backup/",
        "images/chats/",
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

  # dev 전용 파라미터 (공통 파라미터는 모듈 default로 포함)
  extra_parameters = {
    "DB_URL"                       = { type = "String" }        # prod는 SecureString
    "RUNPOD_POLL_TIMEOUT_SECONDS"  = { type = "String" }        # prod는 SecureString
    "QUIZ_CACHE_TTL_SECONDS"       = { type = "String" }
    "REDIS_URL"                    = { type = "SecureString" }
    "SPRING_DATA_REDIS_HOST"       = { type = "String" }
    "SPRING_DATA_REDIS_PORT"       = { type = "String" }
    "NEXT_PUBLIC_API_BASE_URL_DEV"  = { type = "String" }
    "NEXT_PUBLIC_CHAT_BASE_URL_DEV" = { type = "String" }
    "MONGO_URI"                     = { type = "SecureString" }
  }
}
