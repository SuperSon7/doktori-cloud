# =============================================================================
# K8s Node AMI — containerd + kubeadm/kubelet/kubectl
# =============================================================================

# -----------------------------------------------------------------------------
# Source: Ubuntu 22.04 arm64
# -----------------------------------------------------------------------------
source "amazon-ebs" "k8s_node" {
  ami_name        = "${var.project_name}-k8s-node-arm64-${local.timestamp}"
  ami_description = "K8s node arm64 base: containerd ${var.containerd_version}, kubeadm/kubelet/kubectl ${var.k8s_version}, CNI plugins ${var.cni_plugins_version}, ECR credential provider ${var.ecr_credential_provider_version}, crictl ${var.crictl_version}, nerdctl ${var.nerdctl_version}"
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
    Name         = "${var.project_name}-k8s-node-arm64-${local.timestamp}"
    Project      = var.project_name
    AMI_Type     = "k8s-node"
    K8s_Version  = var.k8s_version
    Containerd   = var.containerd_version
    Crictl       = var.crictl_version
    Nerdctl      = var.nerdctl_version
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
    script = "packer/scripts/k8s-node-setup.sh"
    environment_vars = [
      "K8S_VERSION=${var.k8s_version}",
      "CONTAINERD_VERSION=${var.containerd_version}",
      "CNI_PLUGINS_VERSION=${var.cni_plugins_version}",
      "ECR_PROVIDER_VERSION=${var.ecr_credential_provider_version}",
      "CRICTL_VERSION=${var.crictl_version}",
      "NERDCTL_VERSION=${var.nerdctl_version}",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    execute_command = "sudo -S env {{ .Vars }} bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "packer/manifest-k8s-node.json"
    strip_path = true
  }
}
