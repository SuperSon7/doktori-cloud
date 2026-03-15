# =============================================================================
# K8s Node AMI — containerd + kubeadm/kubelet/kubectl
# =============================================================================

# -----------------------------------------------------------------------------
# Source: Ubuntu 22.04 arm64
# -----------------------------------------------------------------------------
source "amazon-ebs" "k8s_node" {
  ami_name      = "${var.project_name}-k8s-node-arm64-${local.timestamp}"
  ami_description = "K8s node: containerd ${var.containerd_version}, kubeadm/kubelet/kubectl ${var.k8s_version}, AWS CLI v2, SSM Agent"
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
    Name         = "${var.project_name}-k8s-node-arm64-${local.timestamp}"
    Project      = var.project_name
    AMI_Type     = "k8s-node"
    K8s_Version  = var.k8s_version
    Containerd   = var.containerd_version
    Architecture = "arm64"
    BuildDate    = local.timestamp
  }
}

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------
build {
  sources = ["source.amazon-ebs.k8s_node"]

  provisioner "shell" {
    script = "scripts/k8s-node-setup.sh"
    environment_vars = [
      "K8S_VERSION=${var.k8s_version}",
      "CONTAINERD_VERSION=${var.containerd_version}",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    execute_command = "sudo -S env {{ .Vars }} bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "manifest-k8s-node.json"
    strip_path = true
  }
}