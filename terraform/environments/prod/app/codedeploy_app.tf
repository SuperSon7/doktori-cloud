# =============================================================================
# Frontend CodeDeploy — Application + Deployment Group
# (Revision Bucket은 stateful이므로 prod/data 레이어에서 관리)
# =============================================================================
resource "aws_codedeploy_app" "frontend_prod" {
  name             = local.frontend_codedeploy_application_name
  compute_platform = "Server"

  tags = {
    Name    = local.frontend_codedeploy_application_name
    Service = "codedeploy"
  }
}
