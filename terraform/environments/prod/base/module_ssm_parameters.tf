# -----------------------------------------------------------------------------
# SSM Parameter Store
# -----------------------------------------------------------------------------
module "ssm_parameters" {
  source = "../../../modules/ssm-parameters"

  project_name = var.project_name
  environment  = var.environment

  # prod 전용 파라미터
  # DB_URL, AI_DB_URL → prod/data 레이어에서 RDS endpoint로 Terraform write
  extra_parameters = {
    "RUNPOD_POLL_TIMEOUT_SECONDS" = { type = "SecureString" }
    "QUIZ_CACHE_TTL_SECONDS"      = { type = "String" }
  }
}
