# =============================================================================
# Dev App AMI — Docker Compose host for docker-compose.dev.yml
# =============================================================================

source "amazon-ebs" "dev_app" {
  ami_name        = "${var.project_name}-dev-app-arm64-${local.timestamp}"
  ami_description = "Dev app Docker Compose host: Docker CE ${var.docker_version}, AWS CLI v2, SSM Agent, CodeDeploy Agent"
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
    Name         = "${var.project_name}-dev-app-arm64-${local.timestamp}"
    Project      = var.project_name
    AMI_Type     = "dev-app"
    Docker       = var.docker_version
    Architecture = "arm64"
    BuildDate    = local.timestamp
  }
}

build {
  sources = ["source.amazon-ebs.dev_app"]

  provisioner "shell" {
    script = "packer/scripts/dev-app-setup.sh"
    environment_vars = [
      "DOCKER_VERSION=${var.docker_version}",
      "AWS_REGION=${var.aws_region}",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    execute_command = "sudo -S env {{ .Vars }} bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "packer/manifest-dev-app.json"
    strip_path = true
  }
}
