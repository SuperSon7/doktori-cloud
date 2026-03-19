# =============================================================================
# Standalone Loadtest Infrastructure — 별도 AWS 계정용
# VPC + EC2 k6 runners (remote_state 의존성 없음)
# =============================================================================

# ── VPC ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "loadtest" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-loadtest-vpc" }
}

resource "aws_internet_gateway" "loadtest" {
  vpc_id = aws_vpc.loadtest.id
  tags   = { Name = "${var.project_name}-loadtest-igw" }
}

resource "aws_subnet" "public" {
  count                   = min(var.runner_count, 2)
  vpc_id                  = aws_vpc.loadtest.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-loadtest-public-${data.aws_availability_zones.available.names[count.index]}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.loadtest.id
  tags   = { Name = "${var.project_name}-loadtest-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.loadtest.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ── IAM (SSM 접속용) ────────────────────────────────────────────────────────

resource "aws_iam_role" "k6_runner" {
  name = "${var.project_name}-loadtest-k6-runner"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.k6_runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "k6_runner" {
  name = "${var.project_name}-loadtest-k6-runner"
  role = aws_iam_role.k6_runner.name
}

# ── Security Group ──────────────────────────────────────────────────────────

resource "aws_security_group" "k6_runner" {
  name_prefix = "${var.project_name}-loadtest-k6-"
  description = "k6 load test runners and monitoring"
  vpc_id      = aws_vpc.loadtest.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-loadtest-k6-sg" }

  lifecycle { create_before_destroy = true }
}

# ── User Data (scripts/ 디렉토리에서 로드) ──────────────────────────────────

# ── EC2 Runners ─────────────────────────────────────────────────────────────

data "aws_ami" "ubuntu_arm64" {
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

resource "aws_instance" "runner" {
  count = var.runner_count

  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = var.instance_type
  key_name               = "doktori-loadtest"
  subnet_id              = aws_subnet.public[count.index % length(aws_subnet.public)].id
  iam_instance_profile   = aws_iam_instance_profile.k6_runner.name
  vpc_security_group_ids = [aws_security_group.k6_runner.id]

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = base64encode(
    count.index == 0
    ? file("${path.module}/scripts/user-data-monitoring.sh")
    : file("${path.module}/scripts/user-data-runner.sh")
  )

  tags = {
    Name    = "${var.project_name}-k6-runner-${count.index + 1}"
    Purpose = "distributed-k6-loadtest"
    Access  = "ssm-only"
  }

  lifecycle { ignore_changes = [ami] }

  depends_on = [
    aws_iam_role_policy_attachment.ssm_managed,
    aws_route.public_internet,
  ]
}