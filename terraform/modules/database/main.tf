# -----------------------------------------------------------------------------
# RDS Security Group
# -----------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-${var.environment}-rds-"
  description = "RDS MySQL - from app instances only"
  vpc_id      = var.vpc_id

  ingress {
    description = "MySQL from VPC"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
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
    Name    = "${var.project_name}-${var.environment}-rds-sg"
    Service = "db"
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
  name  = "/${var.project_name}/${var.environment}/db/password"
  type  = "SecureString"
  value = random_password.db.result

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
  subnet_ids  = var.db_subnet_ids

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

  dynamic "parameter" {
    for_each = var.db_extra_parameters
    content {
      name         = parameter.value.name
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
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
  vpc_security_group_ids = [aws_security_group.rds.id]
  availability_zone      = var.db_availability_zone
  publicly_accessible    = false

  parameter_group_name = aws_db_parameter_group.main.name

  backup_retention_period = var.db_backup_retention
  backup_window           = "18:00-19:00"         # UTC (KST 03:00-04:00)
  maintenance_window      = "Mon:19:00-Mon:20:00" # UTC (KST 월 04:00-05:00)

  auto_minor_version_upgrade = true
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${var.project_name}-${var.environment}-mysql-final"

  tags = {
    Name    = "${var.project_name}-${var.environment}-mysql"
    Service = "db"
  }

  lifecycle {
    prevent_destroy = true
  }
}
