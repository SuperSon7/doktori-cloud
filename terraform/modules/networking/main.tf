# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
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
  availability_zone       = each.value.az_key == "primary" ? var.availability_zone : var.secondary_availability_zone
  map_public_ip_on_launch = each.value.tier == "public"

  tags = {
    Name = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}"
    Tier = each.value.tier
  }
}

# -----------------------------------------------------------------------------
# NAT Instance (t4g.nano — NAT Gateway 대비 비용 절감)
# -----------------------------------------------------------------------------
data "aws_ami" "nat_amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-kernel-*-arm64-gp2"]
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
}

resource "aws_instance" "nat" {
  ami                    = var.nat_ami_id != "" ? var.nat_ami_id : data.aws_ami.nat_amazon_linux.id
  instance_type          = var.nat_instance_type
  key_name               = var.nat_key_name != "" ? var.nat_key_name : null
  subnet_id              = aws_subnet.this[var.nat_subnet_key].id
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false

  user_data = var.nat_user_data != "" ? var.nat_user_data : <<-EOF
    #!/bin/bash
    sysctl -w net.ipv4.ip_forward=1
    iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
  EOF

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(
    {
      Name    = "${var.project_name}-${var.environment}-nat"
      Service = "nat"
    },
    var.nat_extra_tags,
  )

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-${var.environment}-nat-eip"
  }
}

resource "aws_eip_association" "nat" {
  allocation_id = aws_eip.nat.id
  instance_id   = aws_instance.nat.id
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
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.environment}-private-rt"
  }

  lifecycle {
    ignore_changes = [route]
  }
}

# NAT route for private subnets (separate resource to avoid inline conflict)
resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}

# Route Table Associations
resource "aws_route_table_association" "this" {
  for_each = var.subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = each.value.tier == "public" ? aws_route_table.public.id : aws_route_table.private.id
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
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.public.id,
    aws_route_table.private.id,
  ]

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-s3"
  }
}
