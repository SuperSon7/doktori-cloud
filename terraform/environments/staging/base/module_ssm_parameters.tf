# -----------------------------------------------------------------------------
# SSM Parameter Store
# -----------------------------------------------------------------------------
module "ssm_parameters" {
  source = "../../../modules/ssm-parameters"

  project_name = var.project_name
  environment  = var.environment

  # 공통 파라미터는 모듈 default 사용 (dev/prod와 동일)

  # staging 전용 파라미터
  # DB_URL, AI_DB_URL → staging/data 레이어에서 RDS endpoint로 Terraform write
  extra_parameters = {
    "RUNPOD_POLL_TIMEOUT_SECONDS" = { type = "SecureString" }
    "QUIZ_CACHE_TTL_SECONDS"      = { type = "String" }
  }
}
