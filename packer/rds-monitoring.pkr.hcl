# =============================================================================
# RDS Monitoring AMI — Prometheus mysqld_exporter + AWS CLI + SSM Agent
# =============================================================================

source "amazon-ebs" "rds_monitoring" {
  ami_name        = "${var.project_name}-rds-monitoring-arm64-${local.timestamp}"
  ami_description = "Prometheus mysqld_exporter ${var.mysqld_exporter_version}, AWS CLI v2, SSM Agent"
  instance_type   = "t4g.small"
  region          = var.aws_region

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }

  vpc_filter {
    filters = {
      "tag:Name" = var.vpc_filter_name
    }
  }

  subnet_filter {
    filters = {
      "tag:Name" = var.subnet_filter_name
    }
    most_free = true
  }

  associate_public_ip_address               = true
  ssh_username                              = "ubuntu"
  temporary_security_group_source_public_ip = true

  tags = {
    Name            = "${var.project_name}-rds-monitoring-arm64-${local.timestamp}"
    Project         = var.project_name
    AMI_Type        = "rds-monitoring"
    Mysqld_Exporter = var.mysqld_exporter_version
    Architecture    = "arm64"
    BuildDate       = local.timestamp
  }
}

build {
  sources = ["source.amazon-ebs.rds_monitoring"]

  provisioner "shell" {
    script = "packer/scripts/rds-monitoring-setup.sh"
    environment_vars = [
      "MYSQLD_EXPORTER_VERSION=${var.mysqld_exporter_version}",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    execute_command = "sudo -S env {{ .Vars }} bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "packer/manifest-rds-monitoring.json"
    strip_path = true
  }
}
