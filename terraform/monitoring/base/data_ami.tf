# -----------------------------------------------------------------------------
# NAT Instance (WireGuard VPN 진입점 겸용)
# WireGuard 설정은 설치 후 /etc/wireguard/wg0.conf 에서 수동 구성
# -----------------------------------------------------------------------------
data "aws_ami" "nat_golden" {
  owners = ["self"]

  filter {
    name   = "image-id"
    values = [var.nat_ami_id]
  }

  filter {
    name   = "tag:AMI_Type"
    values = ["nat"]
  }
}
