# =============================================================================
# Standalone Loadtest Infrastructure — 별도 AWS 계정용
# VPC + EC2 k6 runners (remote_state 의존성 없음)
# =============================================================================

# ── VPC ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "loadtest" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-loadtest-vpc" }
}
