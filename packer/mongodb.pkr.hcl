# =============================================================================
# MongoDB AMI — MongoDB server + Alloy + AWS CLI + SSM Agent
# =============================================================================

source "amazon-ebs" "mongodb" {
  ami_name        = "${var.project_name}-mongodb-arm64-${local.timestamp}"
  ami_description = "MongoDB ${var.mongodb_version}, Grafana Alloy, AWS CLI v2, SSM Agent"
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
    Name         = "${var.project_name}-mongodb-arm64-${local.timestamp}"
    Project      = var.project_name
    AMI_Type     = "mongodb"
    MongoDB      = var.mongodb_version
    Architecture = "arm64"
    BuildDate    = local.timestamp
  }
}

build {
  sources = ["source.amazon-ebs.mongodb"]

  provisioner "shell" {
    script = "packer/scripts/mongodb-setup.sh"
    environment_vars = [
      "MONGODB_VERSION=${var.mongodb_version}",
      "ALLOY_VERSION=${var.alloy_version}",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    execute_command = "sudo -S env {{ .Vars }} bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "packer/manifest-mongodb.json"
    strip_path = true
  }
}
