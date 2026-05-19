# =============================================================================
# Staging App Layer — compute (downsized instances for cost savings)
# =============================================================================

# -----------------------------------------------------------------------------
# AWS Data Sources — replace terraform_remote_state with direct lookups
# -----------------------------------------------------------------------------
data "aws_vpc" "main" {
  tags = {
    Name = "${var.project_name}-${var.environment}-vpc"
  }
}
