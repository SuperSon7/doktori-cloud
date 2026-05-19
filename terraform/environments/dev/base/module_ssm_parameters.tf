module "ssm_parameters" {
  source = "../../../modules/ssm-parameters"

  project_name = var.project_name
  environment  = var.environment

  # dev 전용 파라미터 (공통 파라미터는 모듈 default로 포함)
  extra_parameters = {
    "AI_DB_URL"                     = { type = "SecureString" } # prod는 data 레이어에서 Terraform write
    "DB_URL"                        = { type = "String" }       # prod는 SecureString
    "RUNPOD_POLL_TIMEOUT_SECONDS"   = { type = "String" }       # prod는 SecureString
    "QUIZ_CACHE_TTL_SECONDS"        = { type = "String" }
    "REDIS_URL"                     = { type = "SecureString" }
    "SPRING_DATA_REDIS_HOST"        = { type = "String" }
    "SPRING_DATA_REDIS_PORT"        = { type = "String" }
    "NEXT_PUBLIC_API_BASE_URL_DEV"  = { type = "String" }
    "NEXT_PUBLIC_CHAT_BASE_URL_DEV" = { type = "String" }
  }
}
