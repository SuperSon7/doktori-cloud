# =============================================================================
# Monitoring App — Compute 레이어
# EC2, IAM, SG, PHZ record
# SG를 base가 아닌 app에 두는 이유:
#   - 서비스 포트 변경이 잦아 compute와 함께 관리하는 것이 자연스러움
# EIP 없음: EC2가 private 서브넷에 있으므로 불필요. 아웃바운드는 NAT, 인바운드는 VPN 경유.
# =============================================================================

# -----------------------------------------------------------------------------
# Remote State — 상위 레이어 참조 (인프라 식별자는 remote_state로 직접 참조)
# -----------------------------------------------------------------------------
data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = "doktori-terraform-state"
    key    = "monitoring/base/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
