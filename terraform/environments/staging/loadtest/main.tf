# =============================================================================
# Staging Loadtest Layer — k6 runner EC2 instances
# =============================================================================

data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.environment}/base/terraform.tfstate"
    region = var.aws_region
  }
}

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

locals {
  net = data.terraform_remote_state.base.outputs.networking

  runner_names = [
    "k6-runner-1",
    "k6-runner-2",
    "k6-runner-3",
  ]

  public_subnet_ids = compact([
    try(local.net.subnet_ids["public"], null),
    try(local.net.subnet_ids["public_c"], null),
    try(local.net.subnet_ids["public_b"], null),
  ])

  runners = {
    for idx, name in local.runner_names : name => {
      subnet_id = local.public_subnet_ids[idx % length(local.public_subnet_ids)]
    }
  }
}

resource "aws_iam_role" "k6_runner" {
  name = "${var.project_name}-${var.environment}-k6-runner"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-k6-runner-role"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.k6_runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "k6_runner" {
  name = "${var.project_name}-${var.environment}-k6-runner"
  role = aws_iam_role.k6_runner.name
}

resource "aws_security_group" "k6_runner" {
  name_prefix = "${var.project_name}-${var.environment}-k6-runner-"
  description = "Security group for k6 load test runners"
  vpc_id      = local.net.vpc_id

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-k6-runner-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "runner" {
  for_each = local.runners

  ami                         = data.aws_ami.ubuntu_arm64.id
  instance_type               = var.instance_type
  subnet_id                   = each.value.subnet_id
  iam_instance_profile        = aws_iam_instance_profile.k6_runner.name
  vpc_security_group_ids      = [aws_security_group.k6_runner.id]
  associate_public_ip_address = true

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

  tags = {
    Name    = each.key
    Project = var.project_tag
    Purpose = "distributed-k6-loadtest"
    Access  = "ssm-only"
  }

  lifecycle {
    ignore_changes = [ami]
  }

  depends_on = [aws_iam_role_policy_attachment.ssm_managed]
}
