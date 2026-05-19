# =============================================================================
# NAT AMI — IP forwarding + persistent MASQUERADE + WireGuard tools + AWS CLI + SSM
# =============================================================================

source "amazon-ebs" "nat" {
  ami_name        = "${var.project_name}-nat-arm64-${local.timestamp}"
  ami_description = "NAT instance arm64 base: ip_forward, persistent MASQUERADE, WireGuard tools, AWS CLI v2, SSM Agent"
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
    Name         = "${var.project_name}-nat-arm64-${local.timestamp}"
    Project      = var.project_name
    AMI_Type     = "nat"
    Architecture = "arm64"
    BuildDate    = local.timestamp
  }
}

build {
  sources = ["source.amazon-ebs.nat"]

  provisioner "shell" {
    script = "packer/scripts/nat-setup.sh"
    environment_vars = [
      "AWS_REGION=${var.aws_region}",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    execute_command = "sudo -S env {{ .Vars }} bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "packer/manifest-nat.json"
    strip_path = true
  }
}
