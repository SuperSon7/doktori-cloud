# -----------------------------------------------------------------------------
# SSM Service-Linked Role (태그 기반 타겟팅에 필요)
# -----------------------------------------------------------------------------
resource "aws_iam_service_linked_role" "ssm" {
  aws_service_name = "ssm.amazonaws.com"
}

resource "aws_iam_service_linked_role" "autoscaling" {
  aws_service_name = "autoscaling.amazonaws.com"
}
