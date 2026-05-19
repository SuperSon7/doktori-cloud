# =============================================================================
# Staging Base Layer — networking (no VPC endpoints for cost savings)
# =============================================================================

# Staging은 disposable 환경이라 NAT만 raw Ubuntu를 명시적으로 전달한다.
# prod처럼 Packer NAT AMI로 고정하지는 않지만, 모듈 내부 fallback은 사용하지 않는다.
data "aws_ami" "nat_ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
