# =============================================================================
# SSM Parameter Store
# =============================================================================

# Qdrant API Key 초기값 — ephemeral: state에 저장되지 않음 (random >= 3.7 필요)
ephemeral "random_password" "qdrant_api_key" {
  length  = 32
  special = false
}
