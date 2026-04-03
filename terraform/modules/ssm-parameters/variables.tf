variable "project_name" {
  type = string
}

variable "environment" {
  description = "SSM 경로에 사용되는 환경 이름 (e.g. dev, prod, staging)"
  type        = string
}

# -----------------------------------------------------------------------------
# 공통 파라미터 — dev/prod 기준 기본값 (staging은 override 가능)
# -----------------------------------------------------------------------------
variable "common_parameters" {
  description = "All environments share these parameters (override for smaller envs like staging)"
  type        = map(object({ type = string }))

  default = {
    # --- AI / ML ---
    # AI_DB_URL → dev/staging은 extra_parameters에서 CHANGE_ME 쉘, prod는 data 레이어에서 Terraform write
    "AI_API_KEY"     = { type = "SecureString" }
    "AI_BASE_URL"    = { type = "String" }
    "GEMINI_API_KEY" = { type = "SecureString" }
    "GEMINI_MODEL"   = { type = "String" }

    # --- RunPod ---
    "RUNPOD_API_KEY"               = { type = "SecureString" }
    "RUNPOD_ENDPOINT_ID"           = { type = "SecureString" }
    "RUNPOD_POLL_INTERVAL_SECONDS" = { type = "String" }

    # --- Database ---
    # DB_PASSWORD는 database 모듈이 관리 (random_password → SSM)
    "DB_USERNAME" = { type = "SecureString" }

    # --- Auth ---
    "JWT_SECRET"              = { type = "SecureString" }
    "KAKAO_CLIENT_ID"         = { type = "SecureString" }
    "KAKAO_CLIENT_SECRET"     = { type = "SecureString" }
    "KAKAO_FRONTEND_REDIRECT" = { type = "String" }
    "KAKAO_REDIRECT_URI"      = { type = "String" }
    "KAKAO_REST_API_KEY"      = { type = "SecureString" }

    # --- AWS ---
    # AWS_REGION, AWS_S3_*, ECR_REGISTRY → 각 레이어 main.tf에서 Terraform이 직접 write (CHANGE_ME 불필요)

    # --- Redis ---
    # SPRING_REDIS_PORT → static "6379", base 레이어에서 Terraform write
    "SPRING_REDIS_HOST"     = { type = "String" }
    "SPRING_REDIS_PASSWORD" = { type = "SecureString" }

    # --- RabbitMQ ---
    # SPRING_RABBITMQ_PORT → static "5672", base 레이어에서 Terraform write
    "SPRING_RABBITMQ_HOST"     = { type = "String" }
    "SPRING_RABBITMQ_PASSWORD" = { type = "SecureString" }
    "SPRING_RABBITMQ_USERNAME" = { type = "SecureString" }

    # --- Recommendation Scheduler ---
    "ENABLE_RECO_SCHEDULER"   = { type = "String" }
    "RECO_SCHEDULER_CRON"     = { type = "String" }
    "RECO_SCHEDULER_SEARCH_K" = { type = "String" }
    "RECO_SCHEDULER_TOP_K"    = { type = "String" }
    "RECO_SCHEDULER_TZ"       = { type = "String" }

    # --- Zoom ---
    "ZOOM_ACCOUNT_ID"    = { type = "SecureString" }
    "ZOOM_CLIENT_ID"     = { type = "SecureString" }
    "ZOOM_CLIENT_SECRET" = { type = "SecureString" }

    # --- Firebase / Push ---
    "FIREBASE_SERVICE_ACCOUNT" = { type = "SecureString" }
  }
}

# -----------------------------------------------------------------------------
# 환경별 추가 파라미터
# -----------------------------------------------------------------------------
variable "extra_parameters" {
  description = "Environment-specific parameters (merged with common)"
  type        = map(object({ type = string }))
  default     = {}
}