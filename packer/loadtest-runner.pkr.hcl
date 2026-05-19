# =============================================================================
# Loadtest Runner AMI — k6 + Docker + AWS CLI + SSM
# =============================================================================

source "amazon-ebs" "loadtest_runner" {
  ami_name        = "${var.project_name}-loadtest-runner-arm64-${local.timestamp}"
  ami_description = "Loadtest runner arm64: k6 ${var.k6_version}, Docker CE ${var.docker_version}, AWS CLI v2, SSM Agent"
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
    Name         = "${var.project_name}-loadtest-runner-arm64-${local.timestamp}"
    Project      = var.project_name
    AMI_Type     = "loadtest-runner"
    K6           = var.k6_version
    Docker       = var.docker_version
    Architecture = "arm64"
    BuildDate    = local.timestamp
  }
}

build {
  sources = ["source.amazon-ebs.loadtest_runner"]

  provisioner "shell" {
    script = "packer/scripts/loadtest-runner-setup.sh"
    environment_vars = [
      "K6_VERSION=${var.k6_version}",
      "AWS_REGION=${var.aws_region}",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    execute_command = "sudo -S env {{ .Vars }} bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "packer/manifest-loadtest-runner.json"
    strip_path = true
  }
}
