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

  db_name             = var.db_name
  username            = var.db_username
  password_wo         = ephemeral.aws_ssm_parameter.db_password.value
  password_wo_version = 1

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  availability_zone      = var.db_availability_zone
  publicly_accessible    = false

  parameter_group_name = aws_db_parameter_group.main.name

  backup_retention_period = var.db_backup_retention
  backup_window           = "18:00-19:00"         # UTC (KST 03:00-04:00)
  maintenance_window      = "Mon:19:00-Mon:20:00" # UTC (KST 월 04:00-05:00)

  auto_minor_version_upgrade = true
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = var.skip_final_snapshot
  final_snapshot_identifier  = var.skip_final_snapshot ? null : "${var.project_name}-${var.environment}-mysql-final"

  tags = {
    Name    = "${var.project_name}-${var.environment}-mysql"
    Service = "db"
  }

  lifecycle {
    prevent_destroy = true
  }
}
