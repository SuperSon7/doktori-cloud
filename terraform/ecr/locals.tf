# =============================================================================
# ECR Repositories (계정 레벨, 리전 리소스)
# =============================================================================

locals {
  # dev/prod 단일 레포 — 이미지 태그로 환경 구분
  # dev 빌드: dev-${GIT_SHA}
  # prod 빌드: prod-${GIT_SHA}
  # lifecycle rule: 각 prefix 10개 유지, untagged 1일 후 삭제
  repositories = {
    backend_api  = "doktori/backend-api"
    backend_chat = "doktori/backend-chat"
    ai           = "doktori/ai"
    frontend     = "doktori/frontend"
    nginx        = "doktori/nginx"
  }
}
