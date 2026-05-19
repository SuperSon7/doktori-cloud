locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu_arm64[0].id
}
