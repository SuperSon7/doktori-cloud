# =============================================================================
# Dev AI AMI — Docker host for dev AI, batch, and Qdrant workloads
# =============================================================================

source "amazon-ebs" "dev_ai" {
  ami_name        = "${var.project_name}-dev-ai-arm64-${local.timestamp}"
  ami_description = "Dev AI Docker host: Docker CE ${var.docker_version}, AWS CLI v2, SSM Agent"
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
    Name         = "${var.project_name}-dev-ai-arm64-${local.timestamp}"
    Project      = var.project_name
    AMI_Type     = "dev-ai"
    Docker       = var.docker_version
    Architecture = "arm64"
    BuildDate    = local.timestamp
  }
}

build {
  sources = ["source.amazon-ebs.dev_ai"]

  provisioner "shell" {
    script = "packer/scripts/dev-ai-setup.sh"
    environment_vars = [
      "DOCKER_VERSION=${var.docker_version}",
      "AWS_REGION=${var.aws_region}",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    execute_command = "sudo -S env {{ .Vars }} bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "packer/manifest-dev-ai.json"
    strip_path = true
  }
}
