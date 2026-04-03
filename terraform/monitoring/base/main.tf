# =============================================================================
# Monitoring Base — mgmt VPC 네트워크 레이어
# PHZ, NAT 인스턴스 (WireGuard VPN 겸용), VPC Peering Routes
#
# default VPC 대신 전용 VPC를 사용하는 이유:
#   - default VPC는 서브넷/IGW 구조 변경 불가 → monitoring EC2를 private에 배치 불가
#   - 전용 VPC(172.16.0.0/16)로 분리해 네트워크 경계를 명확히 함
#   - NAT 인스턴스(~$3/월)로 private 아웃바운드 처리 (NAT Gateway ~$32/월 대비 절감)
# =============================================================================

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
resource "aws_vpc" "mgmt" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-mgmt-vpc" }
}

resource "aws_internet_gateway" "mgmt" {
  vpc_id = aws_vpc.mgmt.id

  tags = { Name = "${var.project_name}-mgmt-igw" }
}

# -----------------------------------------------------------------------------
# Subnets
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.mgmt.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-mgmt-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.mgmt.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone

  tags = { Name = "${var.project_name}-mgmt-private" }
}

# -----------------------------------------------------------------------------
# NAT Instance (WireGuard VPN 진입점 겸용)
# WireGuard 설정은 설치 후 /etc/wireguard/wg0.conf 에서 수동 구성
# -----------------------------------------------------------------------------
data "aws_ami" "nat_ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "nat" {
  name        = "${var.project_name}-mgmt-nat-sg"
  description = "mgmt NAT instance - WireGuard VPN + private subnet NAT forwarding"
  vpc_id      = aws_vpc.mgmt.id

  ingress {
    description = "All traffic from mgmt VPC (NAT forwarding)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "WireGuard VPN"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-mgmt-nat-sg"
    Service = "nat-vpn"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role" "nat" {
  name = "${var.project_name}-mgmt-nat-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.project_name}-mgmt-nat-role" }
}

resource "aws_iam_role_policy_attachment" "nat_ssm" {
  role       = aws_iam_role.nat.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat" {
  name = "${var.project_name}-mgmt-nat-profile"
  role = aws_iam_role.nat.name
}

resource "aws_instance" "nat" {
  ami                    = data.aws_ami.nat_ubuntu.id
  instance_type          = var.nat_instance_type
  key_name               = var.nat_key_name != "" ? var.nat_key_name : null
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false
  iam_instance_profile   = aws_iam_instance_profile.nat.name

  user_data = <<-USERDATA
    #!/bin/bash
    set -e

    # IP forwarding 활성화
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p

    # iptables MASQUERADE (아웃바운드 인터페이스 자동 감지)
    IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
    iptables -t nat -A POSTROUTING -o "$IFACE" -s ${var.vpc_cidr} -j MASQUERADE

    # iptables 영속화
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent wireguard

    netfilter-persistent save
    # WireGuard 설정은 /etc/wireguard/wg0.conf 에서 수동 구성 후 systemctl enable --now wg-quick@wg0
  USERDATA

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = "${var.project_name}-mgmt-nat-vpn"
    Service = "nat-vpn"
    Owner   = "cloud"
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_internet_gateway.mgmt]
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.project_name}-mgmt-nat-eip" }
}

resource "aws_eip_association" "nat" {
  allocation_id = aws_eip.nat.id
  instance_id   = aws_instance.nat.id
}

# -----------------------------------------------------------------------------
# Route Tables
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.mgmt.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.mgmt.id
  }

  tags = { Name = "${var.project_name}-mgmt-public-rt" }

  lifecycle {
    # VPC peering route는 aws_route 리소스로 별도 관리
    ignore_changes = [route]
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.mgmt.id

  tags = { Name = "${var.project_name}-mgmt-private-rt" }

  lifecycle {
    # VPC peering route는 aws_route 리소스로 별도 관리
    ignore_changes = [route]
  }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# -----------------------------------------------------------------------------
# Private Hosted Zone — mgmt.{project}.internal
# peered VPC association은 aws_route53_zone_association으로 추가 → ignore_changes로 drift 방지
# -----------------------------------------------------------------------------
resource "aws_route53_zone" "mgmt" {
  name = "mgmt.${var.project_name}.internal"

  vpc {
    vpc_id = aws_vpc.mgmt.id
  }

  tags = {
    Name    = "mgmt.${var.project_name}.internal"
    Service = "monitoring"
  }

  lifecycle {
    prevent_destroy = true
    # peered VPC association은 aws_route53_zone_association으로 추가되므로
    # Terraform이 이 변경을 drift로 감지하고 제거하지 않도록 ignore
    ignore_changes = [vpc]
  }
}

# =============================================================================
# VPC Peering Routes — mgmt ↔ environment VPCs
# 각 환경의 peering connection은 env/base에서 생성, 역방향 route만 여기서 관리
# =============================================================================
data "aws_vpc_peering_connections" "env_peerings" {
  filter {
    name   = "status-code"
    values = ["active"]
  }

  # vpc-id 대신 cidr-block으로 필터링 — vpc-id는 apply 전까지 unknown이라 for_each 불가
  filter {
    name   = "accepter-vpc-info.cidr-block"
    values = [var.vpc_cidr]
  }
}

data "aws_vpc_peering_connection" "env" {
  for_each = toset(data.aws_vpc_peering_connections.env_peerings.ids)
  id       = each.value
}

# private 서브넷 → env VPC (monitoring EC2 outbound)
resource "aws_route" "private_to_env" {
  for_each = data.aws_vpc_peering_connection.env

  route_table_id            = aws_route_table.private.id
  destination_cidr_block    = each.value.cidr_block
  vpc_peering_connection_id = each.value.id
}

# public 서브넷 → env VPC (WireGuard VPN 클라이언트가 peered VPC에 접근하기 위한 route)
resource "aws_route" "public_to_env" {
  for_each = data.aws_vpc_peering_connection.env

  route_table_id            = aws_route_table.public.id
  destination_cidr_block    = each.value.cidr_block
  vpc_peering_connection_id = each.value.id
}

resource "aws_route53_zone_association" "mgmt_phz_env" {
  for_each = data.aws_vpc_peering_connection.env

  zone_id = aws_route53_zone.mgmt.id
  vpc_id  = each.value.vpc_id
}
