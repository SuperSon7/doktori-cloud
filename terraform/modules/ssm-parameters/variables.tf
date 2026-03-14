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
    "AI_API_KEY"     = { type = "SecureString" }
    "AI_BASE_URL"    = { type = "String" }
    "AI_DB_URL"      = { type = "SecureString" }
    "GEMINI_API_KEY" = { type = "SecureString" }
    "GEMINI_MODEL"   = { type = "String" }

    # --- RunPod ---
    "RUNPOD_API_KEY"               = { type = "SecureString" }
    "RUNPOD_ENDPOINT_ID"           = { type = "SecureString" }
    "RUNPOD_POLL_INTERVAL_SECONDS" = { type = "SecureString" }

    # --- Database ---
    # DB_PASSWORD는 database 모듈이 관리 (random_password → SSM)
    "DB_NAME"     = { type = "SecureString" }
    "DB_USERNAME" = { type = "SecureString" }

    # --- Auth ---
    "JWT_SECRET"              = { type = "SecureString" }
    "KAKAO_CLIENT_ID"         = { type = "SecureString" }
    "KAKAO_CLIENT_SECRET"     = { type = "SecureString" }
    "KAKAO_FRONTEND_REDIRECT" = { type = "SecureString" }
    "KAKAO_REDIRECT_URI"      = { type = "SecureString" }
    "KAKAO_REST_API_KEY"      = { type = "SecureString" }

    # --- AWS ---
    "AWS_DEPLOY_ROLE_ARN" = { type = "String" }
    "AWS_REGION"          = { type = "SecureString" }
    "AWS_S3_BUCKET_NAME"  = { type = "SecureString" }
    "AWS_S3_DB_BACKUP"    = { type = "SecureString" }
    "AWS_S3_ENABLED"      = { type = "SecureString" }
    "AWS_S3_ENDPOINT"     = { type = "SecureString" }
    "ECR_REGISTRY"        = { type = "String" }

    # --- Redis ---
    "SPRING_REDIS_HOST" = { type = "String" }
    "SPRING_REDIS_PORT" = { type = "String" }

    # --- RabbitMQ ---
    "SPRING_RABBITMQ_HOST"     = { type = "String" }
    "SPRING_RABBITMQ_PASSWORD" = { type = "SecureString" }
    "SPRING_RABBITMQ_PORT"     = { type = "String" }
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

    # --- CI/CD ---
    "DISCORD_WEBHOOK_URL" = { type = "SecureString" }
    "QODANA_TOKEN"        = { type = "SecureString" }
    "SENTRY_AUTH_TOKEN"   = { type = "SecureString" }

    # --- Firebase / Push ---
    "FIREBASE_SERVICE_ACCOUNT" = { type = "SecureString" }

    # --- Frontend (NEXT_PUBLIC) ---
    "NEXT_PUBLIC_CHAT_WS_PATH"                 = { type = "String" }
    "NEXT_PUBLIC_GA_ID"                        = { type = "String" }
    "NEXT_PUBLIC_FIREBASE_API_KEY"             = { type = "String" }
    "NEXT_PUBLIC_FIREBASE_APPID"               = { type = "String" }
    "NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN"         = { type = "String" }
    "NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID" = { type = "String" }
    "NEXT_PUBLIC_FIREBASE_PROJECT_ID"          = { type = "String" }
    "NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET"      = { type = "String" }
    "NEXT_PUBLIC_FIREBASE_VAPID_KEY"           = { type = "String" }
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