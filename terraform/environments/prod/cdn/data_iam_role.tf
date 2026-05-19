# -----------------------------------------------------------------------------
# GitHub Actions Deploy Role — CDN 배포 권한 (리소스 생성 후 attachment)
# role 자체는 global 레이어에서 생성, 리소스 종속 policy는 여기서 관리
# -----------------------------------------------------------------------------
data "aws_iam_role" "gha_deploy" {
  name = "${var.project_name}-gha-deploy"
}
