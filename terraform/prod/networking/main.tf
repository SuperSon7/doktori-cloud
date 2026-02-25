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
# Subnets
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-${var.environment}-public"
    Tier = "public"
  }
}

resource "aws_subnet" "private_app" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_app_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${var.project_name}-${var.environment}-private-app"
    Tier = "private-app"
  }
}

resource "aws_subnet" "private_db" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_db_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${var.project_name}-${var.environment}-private-db"
    Tier = "private-db"
  }
}

resource "aws_subnet" "private_rds" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_rds_subnet_cidr
  availability_zone = var.secondary_availability_zone

  tags = {
    Name = "${var.project_name}-${var.environment}-private-rds"
    Tier = "private-db"
  }
}

# -----------------------------------------------------------------------------
# NAT Instance (t4g.nano) — 관리형 NAT Gateway 대비 비용 절감
# -----------------------------------------------------------------------------
data "aws_ami" "nat_arm64" {
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
  ami                    = data.aws_ami.nat_arm64.id
  instance_type          = "t4g.nano"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false

  user_data = <<-EOF
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

  tags = {
    Name    = "${var.project_name}-${var.environment}-nat"
    Service = "nat"
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-${var.environment}-nat-eip"
  }
}

resource "aws_eip_association" "nat" {
  instance_id   = aws_instance.nat.id
  allocation_id = aws_eip.nat.id
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

  # 0.0.0.0/0 → NAT 인스턴스 라우팅은 Terraform 외부에서 관리
  # (NAT 인스턴스 교체 시 수동으로 route 업데이트 필요)

  tags = {
    Name = "${var.project_name}-${var.environment}-private-rt"
  }

  lifecycle {
    ignore_changes = [route]
  }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_app" {
  subnet_id      = aws_subnet.private_app.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_db" {
  subnet_id      = aws_subnet.private_db.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_rds" {
  subnet_id      = aws_subnet.private_rds.id
  route_table_id = aws_route_table.private.id
}

# -----------------------------------------------------------------------------
# VPC Endpoints - Interface (SSM, ECR, CloudWatch Logs)
# -----------------------------------------------------------------------------
resource "aws_security_group" "vpc_endpoints" {
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

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.private_app.id]
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-ssm"
  }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.private_app.id]
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-ssmmessages"
  }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.private_app.id]
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-ec2messages"
  }
}

resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.private_app.id]
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-ecr-api"
  }
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.private_app.id]
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-ecr-dkr"
  }
}

resource "aws_vpc_endpoint" "logs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.private_app.id]
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = {
    Name = "${var.project_name}-${var.environment}-vpce-logs"
  }
}

# VPC Endpoint - Gateway (S3)
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
