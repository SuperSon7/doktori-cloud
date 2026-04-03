# =============================================================================
# VPC
# =============================================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-${var.environment}-vpc"
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.environment}-igw"
  }
}

# -----------------------------------------------------------------------------
# Subnets (for_each)
# -----------------------------------------------------------------------------
resource "aws_subnet" "this" {
  for_each = var.subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = (
    each.value.az_key == "primary"   ? var.availability_zone :
    each.value.az_key == "tertiary"  ? var.tertiary_availability_zone :
                                       var.secondary_availability_zone
  )
  map_public_ip_on_launch = each.value.tier == "public"

  tags = {
    Name = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}"
  }
}

# -----------------------------------------------------------------------------
# NAT Instance (t4g.nano — NAT Gateway 대비 비용 절감)
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
  name_prefix = "${var.project_name}-${var.environment}-nat-"
  description = "NAT instance - forward traffic from private subnets"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "All traffic from VPC (NAT forwarding)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  dynamic "ingress" {
    for_each = var.nat_extra_ingress
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
    }
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-nat-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  nat_instances = var.nat_instances != null ? var.nat_instances : {
    primary = { subnet_key = var.nat_subnet_key }
  }

  # Map each private subnet to its NAT key based on az_key
  # Falls back to "primary" if no NAT exists for that AZ
  subnet_nat_key = {
    for k, v in var.subnets : k =>
    v.tier == "public" ? null :
    contains(keys(local.nat_instances), v.az_key) ? v.az_key : "primary"
  }
}

# --- NAT Instance IAM (SSM access) ---
resource "aws_iam_role" "nat" {
  count = var.nat_iam_instance_profile == "" ? 1 : 0

  name = "${var.project_name}-${var.environment}-nat-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.project_name}-${var.environment}-nat-role" }
}

resource "aws_iam_role_policy_attachment" "nat_ssm" {
  count = var.nat_iam_instance_profile == "" ? 1 : 0

  role       = aws_iam_role.nat[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat" {
  count = var.nat_iam_instance_profile == "" ? 1 : 0

  name = "${var.project_name}-${var.environment}-nat-profile"
  role = aws_iam_role.nat[0].name
}

locals {
  nat_instance_profile = var.nat_iam_instance_profile != "" ? var.nat_iam_instance_profile : (
    length(aws_iam_instance_profile.nat) > 0 ? aws_iam_instance_profile.nat[0].name : null
  )
}

resource "aws_instance" "nat" {
  for_each = local.nat_instances

  ami                    = var.nat_ami_id != "" ? var.nat_ami_id : data.aws_ami.nat_ubuntu.id
  instance_type          = var.nat_instance_type
  key_name               = var.nat_key_name != "" ? var.nat_key_name : null
  subnet_id              = aws_subnet.this[each.value.subnet_key].id
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false
  iam_instance_profile   = local.nat_instance_profile

  user_data = var.nat_user_data != "" ? var.nat_user_data : <<-EOF
    #!/bin/bash
    sysctl -w net.ipv4.ip_forward=1
    DEFAULT_IF=$(ip route show default | awk '{print $5}')
    iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE
  EOF

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = var.nat_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(
    {
      Name    = "${var.project_name}-${var.environment}-nat-${each.key}"
      Service = "nat"
    },
    var.nat_extra_tags,
  )

  lifecycle {
    # most_recent AMI는 apply마다 달라지므로 재생성 방지. user_data는 초기 설정 후 변경 불필요
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_eip" "nat" {
  for_each = local.nat_instances

  domain = "vpc"

  tags = {
    Name = "${var.project_name}-${var.environment}-nat-${each.key}-eip"
  }
}

resource "aws_eip_association" "nat" {
  for_each = local.nat_instances

  allocation_id = aws_eip.nat[each.key].id
  instance_id   = aws_instance.nat[each.key].id
}

# --- moved blocks: 기존 단일 NAT → for_each["primary"]로 무중단 전환 ---
moved {
  from = aws_instance.nat
  to   = aws_instance.nat["primary"]
}

moved {
  from = aws_eip.nat
  to   = aws_eip.nat["primary"]
}

moved {
  from = aws_eip_association.nat
  to   = aws_eip_association.nat["primary"]
}

# -----------------------------------------------------------------------------
# Route Tables
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-public-rt"
  }

  # 별도 aws_route 리소스(VPC peering 등)로 추가된 route와 충돌 방지
  lifecycle {
    ignore_changes = [route]
  }
}

resource "aws_route_table" "private" {
  for_each = local.nat_instances

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.environment}-private-${each.key}-rt"
  }

  lifecycle {
    ignore_changes = [route]
  }
}

# NAT route for private subnets (per AZ)
resource "aws_route" "private_nat" {
  for_each = local.nat_instances

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[each.key].primary_network_interface_id
}

# Route Table Associations
resource "aws_route_table_association" "this" {
  for_each = var.subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = (
    each.value.tier == "public"
    ? aws_route_table.public.id
    : aws_route_table.private[local.subnet_nat_key[each.key]].id
  )
}

# --- moved blocks: 기존 단일 route table → for_each["primary"] ---
moved {
  from = aws_route_table.private
  to   = aws_route_table.private["primary"]
}

moved {
  from = aws_route.private_nat
  to   = aws_route.private_nat["primary"]
}

# -----------------------------------------------------------------------------
# VPC Endpoints — Interface (SSM, ECR, CloudWatch Logs)
# -----------------------------------------------------------------------------
resource "aws_security_group" "vpc_endpoints" {
  count = length(var.vpc_interface_endpoints) > 0 ? 1 : 0

  name_prefix = "${var.project_name}-${var.environment}-vpce-"
  description = "Security group for VPC endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-sg"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.vpc_interface_endpoints)

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.this[var.vpc_endpoint_subnet_key].id]
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-${replace(each.value, ".", "-")}"
  }
}

# VPC Endpoint — Gateway (S3)
# -----------------------------------------------------------------------------
# Route53 Private Hosted Zone
# -----------------------------------------------------------------------------
resource "aws_route53_zone" "internal" {
  name = var.internal_domain

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = {
    Name = var.internal_domain
  }
}

# VPC Endpoint — Gateway (S3)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    [aws_route_table.public.id],
    [for k, v in aws_route_table.private : v.id],
  )

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-s3"
  }
}
