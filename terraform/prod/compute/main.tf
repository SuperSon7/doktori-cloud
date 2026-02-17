# -----------------------------------------------------------------------------
# Remote State References
# -----------------------------------------------------------------------------
data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod/networking/terraform.tfstate"
    region = var.aws_region
  }
}

# -----------------------------------------------------------------------------
# AMI Data Source
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu_x86" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# IAM Role for EC2 Instances (SSM + S3 + Parameter Store + ECR)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ec2_ssm" {
  name = "${var.project_name}-${var.environment}-ec2-ssm"

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
    Name = "${var.project_name}-${var.environment}-ec2-ssm"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ec2_s3_access" {
  name = "${var.project_name}-${var.environment}-ec2-s3"
  role = aws_iam_role.ec2_ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::${var.project_name}-${var.environment}-*",
          "arn:aws:s3:::${var.project_name}-${var.environment}-*/*",
        ]
      },
    ]
  })
}

resource "aws_iam_role_policy" "ec2_parameter_store" {
  name = "${var.project_name}-${var.environment}-ec2-ssm-params"
  role = aws_iam_role.ec2_ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
        ]
        Resource = "arn:aws:kms:${var.aws_region}:*:key/*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "ec2_ecr_pull" {
  name = "${var.project_name}-${var.environment}-ec2-ecr-pull"
  role = aws_iam_role.ec2_ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:*:repository/${var.project_name}/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${var.project_name}-${var.environment}-ec2-ssm"
  role = aws_iam_role.ec2_ssm.name
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

# nginx SG - public facing
resource "aws_security_group" "nginx" {
  name_prefix = "${var.project_name}-${var.environment}-nginx-"
  description = "Nginx reverse proxy - public HTTP/HTTPS"
  vpc_id      = data.terraform_remote_state.networking.outputs.vpc_id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
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

  tags = {
    Name    = "${var.project_name}-${var.environment}-nginx-sg"
    Service = "nginx"
  }
}

# front SG - from nginx only
resource "aws_security_group" "front" {
  name_prefix = "${var.project_name}-${var.environment}-front-"
  description = "Frontend - from nginx only"
  vpc_id      = data.terraform_remote_state.networking.outputs.vpc_id

  ingress {
    description     = "HTTP from nginx"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.nginx.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-front-sg"
    Service = "front"
  }
}

# api SG - from nginx only (8080=blue, 8082=green)
resource "aws_security_group" "api" {
  name_prefix = "${var.project_name}-${var.environment}-api-"
  description = "API server - from nginx only"
  vpc_id      = data.terraform_remote_state.networking.outputs.vpc_id

  ingress {
    description     = "HTTP from nginx (blue/green)"
    from_port       = 8080
    to_port         = 8082
    protocol        = "tcp"
    security_groups = [aws_security_group.nginx.id]
  }

  ingress {
    description = "Node Exporter from VPC (monitoring)"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.networking.outputs.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-api-sg"
    Service = "api"
  }
}

# chat SG - from nginx only (8081=blue, 8083=green)
resource "aws_security_group" "chat" {
  name_prefix = "${var.project_name}-${var.environment}-chat-"
  description = "Chat server - from nginx only"
  vpc_id      = data.terraform_remote_state.networking.outputs.vpc_id

  ingress {
    description     = "HTTP from nginx (blue/green)"
    from_port       = 8081
    to_port         = 8083
    protocol        = "tcp"
    security_groups = [aws_security_group.nginx.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-chat-sg"
    Service = "chat"
  }
}

# ai SG - from nginx only
resource "aws_security_group" "ai" {
  name_prefix = "${var.project_name}-${var.environment}-ai-"
  description = "AI server - from nginx only"
  vpc_id      = data.terraform_remote_state.networking.outputs.vpc_id

  ingress {
    description     = "HTTP from nginx"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.nginx.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-ai-sg"
    Service = "ai"
  }
}

# db SG - from api and chat only
resource "aws_security_group" "db" {
  name_prefix = "${var.project_name}-${var.environment}-db-"
  description = "MySQL DB - from api and chat only"
  vpc_id      = data.terraform_remote_state.networking.outputs.vpc_id

  ingress {
    description     = "MySQL from api"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
  }

  ingress {
    description     = "MySQL from chat"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.chat.id]
  }

  ingress {
    description = "MySQL Exporter from VPC (monitoring)"
    from_port   = 9104
    to_port     = 9104
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.networking.outputs.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-db-sg"
    Service = "db"
  }
}

# -----------------------------------------------------------------------------
# EC2 Instances
# -----------------------------------------------------------------------------

# nginx EC2 (Public Subnet - reverse proxy + Let's Encrypt)
resource "aws_instance" "nginx" {
  ami                    = data.aws_ami.ubuntu_x86.id
  instance_type          = var.nginx_instance_type
  key_name               = var.key_name
  subnet_id              = data.terraform_remote_state.networking.outputs.public_subnet_id
  vpc_security_group_ids = [aws_security_group.nginx.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-nginx"
    Service = "nginx"
    Part    = "cloud"
  }
}

resource "aws_eip" "nginx" {
  instance = aws_instance.nginx.id
  domain   = "vpc"

  tags = {
    Name    = "${var.project_name}-${var.environment}-nginx-eip"
    Service = "nginx"
  }
}

# front EC2 (Private App Subnet)
resource "aws_instance" "front" {
  ami                    = data.aws_ami.ubuntu_x86.id
  instance_type          = var.front_instance_type
  key_name               = var.key_name
  subnet_id              = data.terraform_remote_state.networking.outputs.private_app_subnet_id
  vpc_security_group_ids = [aws_security_group.front.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-front"
    Service = "front"
    Part    = "fe"
  }
}

# api EC2 (Private App Subnet)
resource "aws_instance" "api" {
  ami                    = data.aws_ami.ubuntu_x86.id
  instance_type          = var.api_instance_type
  key_name               = var.key_name
  subnet_id              = data.terraform_remote_state.networking.outputs.private_app_subnet_id
  vpc_security_group_ids = [aws_security_group.api.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-api"
    Service = "api"
    Part    = "be"
  }
}

# chat EC2 (Private App Subnet)
resource "aws_instance" "chat" {
  ami                    = data.aws_ami.ubuntu_x86.id
  instance_type          = var.chat_instance_type
  key_name               = var.key_name
  subnet_id              = data.terraform_remote_state.networking.outputs.private_app_subnet_id
  vpc_security_group_ids = [aws_security_group.chat.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-chat"
    Service = "chat"
    Part    = "be"
  }
}

# ai EC2 (Private App Subnet)
resource "aws_instance" "ai" {
  ami                    = data.aws_ami.ubuntu_x86.id
  instance_type          = var.ai_instance_type
  key_name               = var.key_name
  subnet_id              = data.terraform_remote_state.networking.outputs.private_app_subnet_id
  vpc_security_group_ids = [aws_security_group.ai.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-ai"
    Service = "ai"
    Part    = "ai"
  }
}

# db EC2 (Private DB Subnet)
resource "aws_instance" "db" {
  ami                    = data.aws_ami.ubuntu_x86.id
  instance_type          = var.db_instance_type
  key_name               = var.key_name
  subnet_id              = data.terraform_remote_state.networking.outputs.private_db_subnet_id
  vpc_security_group_ids = [aws_security_group.db.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = var.db_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-db"
    Service = "db"
    Part    = "be"
    Backup  = "daily"
  }
}
