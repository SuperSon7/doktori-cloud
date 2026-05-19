# =============================================================================
# Monitoring Base — mgmt VPC 네트워크 레이어
# PHZ, NAT 인스턴스 (WireGuard VPN 겸용), VPC Peering Routes
#
# default VPC 대신 전용 VPC를 사용하는 이유:
#   - default VPC는 서브넷/IGW 구조 변경 불가 → monitoring EC2를 private에 배치 불가
#   - 전용 VPC(172.16.0.0/16)로 분리해 네트워크 경계를 명확히 함
#   - NAT 인스턴스(~$3/월)로 private 아웃바운드 처리 (NAT Gateway ~$32/월 대비 절감)
# =============================================================================

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
resource "aws_vpc" "mgmt" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-mgmt-vpc" }
}
