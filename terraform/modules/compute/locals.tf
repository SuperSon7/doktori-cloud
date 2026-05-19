locals {
  default_ami = {
    arm64 = var.custom_ami_id != "" ? var.custom_ami_id : data.aws_ami.ubuntu_arm64.id
    x86   = data.aws_ami.ubuntu_x86.id
  }

  name_prefix = var.name_suffix == "" ? "${var.project_name}-${var.environment}" : "${var.project_name}-${var.environment}-${var.name_suffix}"
}
