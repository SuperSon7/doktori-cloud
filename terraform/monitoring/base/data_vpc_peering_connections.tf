# =============================================================================
# VPC Peering Routes — mgmt ↔ environment VPCs
# 각 환경의 peering connection은 env/base에서 생성, 역방향 route만 여기서 관리
# =============================================================================
data "aws_vpc_peering_connections" "env_peerings" {
  filter {
    name   = "status-code"
    values = ["active"]
  }

  # vpc-id 대신 cidr-block으로 필터링 — vpc-id는 apply 전까지 unknown이라 for_each 불가
  filter {
    name   = "accepter-vpc-info.cidr-block"
    values = [var.vpc_cidr]
  }
}
