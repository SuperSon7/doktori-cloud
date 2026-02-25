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

data "terraform_remote_state" "compute" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod/compute/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "storage" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod/storage/terraform.tfstate"
    region = var.aws_region
  }
}

# -----------------------------------------------------------------------------
# DB Password (random → SSM Parameter Store)
# -----------------------------------------------------------------------------
resource "random_password" "db" {
  length  = 20
  special = false
}

resource "aws_ssm_parameter" "db_password" {
  name   = "/${var.project_name}/${var.environment}/db/password"
  type   = "SecureString"
  value  = random_password.db.result
  key_id = data.terraform_remote_state.storage.outputs.kms_key_arn

  tags = {
    Name = "${var.project_name}-${var.environment}-db-password"
  }
}

# -----------------------------------------------------------------------------
# DB Subnet Group (2 AZ 필수 요구사항)
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name        = "${var.project_name}-${var.environment}-db-subnet-group"
  description = "DB subnet group for ${var.project_name} ${var.environment}"

  subnet_ids = [
    data.terraform_remote_state.networking.outputs.private_db_subnet_id,   # ap-northeast-2a
    data.terraform_remote_state.networking.outputs.private_rds_subnet_id,  # ap-northeast-2c
  ]

  tags = {
    Name = "${var.project_name}-${var.environment}-db-subnet-group"
  }
}

# -----------------------------------------------------------------------------
# DB Parameter Group
# -----------------------------------------------------------------------------
resource "aws_db_parameter_group" "main" {
  name        = "${var.project_name}-${var.environment}-mysql80"
  family      = "mysql8.0"
  description = "MySQL 8.0 parameter group for ${var.project_name} ${var.environment}"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  parameter {
    name  = "time_zone"
    value = "Asia/Seoul"
  }
}

# -----------------------------------------------------------------------------
# RDS Instance
# -----------------------------------------------------------------------------
resource "aws_db_instance" "main" {
  identifier     = "${var.project_name}-${var.environment}-mysql"
  engine         = "mysql"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [data.terraform_remote_state.compute.outputs.db_sg_id]
  availability_zone      = var.db_availability_zone
  publicly_accessible    = false

  parameter_group_name = aws_db_parameter_group.main.name

  backup_retention_period = var.db_backup_retention
  backup_window           = "18:00-19:00"   # UTC (KST 03:00-04:00)
  maintenance_window      = "Mon:19:00-Mon:20:00" # UTC (KST 월 04:00-05:00)

  auto_minor_version_upgrade = true
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${var.project_name}-${var.environment}-mysql-final"

  tags = {
    Name    = "${var.project_name}-${var.environment}-mysql"
    Service = "db"
  }
}