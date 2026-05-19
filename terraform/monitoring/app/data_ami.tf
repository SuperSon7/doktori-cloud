# -----------------------------------------------------------------------------
# AMI — 아키텍처 변경 시 variable만 수정하면 자동 전환
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name = "name"
    values = [var.architecture == "arm64"
      ? "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"
    : "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
