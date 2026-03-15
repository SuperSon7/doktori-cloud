# =============================================================================
# Frontend AMI — Docker CE + Compose + ECR login
# =============================================================================

# -----------------------------------------------------------------------------
# Source: Ubuntu 22.04 arm64
# -----------------------------------------------------------------------------
source "amazon-ebs" "frontend" {
  ami_name      = "${var.project_name}-frontend-arm64-${local.timestamp}"
  ami_description = "Frontend: Docker CE ${var.docker_version}, AWS CLI v2, SSM Agent"
  instance_type = "t4g.small"
  region        = var.aws_region

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

  associate_public_ip_address = true
  ssh_username                = "ubuntu"
  temporary_security_group_source_cidrs = ["0.0.0.0/0"]

  tags = {
    Name         = "${var.project_name}-frontend-arm64-${local.timestamp}"
    Project      = var.project_name
    AMI_Type     = "frontend"
    Docker       = var.docker_version
    Architecture = "arm64"
    BuildDate    = local.timestamp
  }
}

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------
build {
  sources = ["source.amazon-ebs.frontend"]

  provisioner "shell" {
    script = "scripts/frontend-setup.sh"
    environment_vars = [
      "DOCKER_VERSION=${var.docker_version}",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    execute_command = "sudo -S env {{ .Vars }} bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "manifest-frontend.json"
    strip_path = true
  }
}
