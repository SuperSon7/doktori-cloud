# =============================================================================
# ECR Repositories (계정 레벨, 리전 리소스)
# =============================================================================

locals {
  repositories = {
    # --- dev/staging 공용 ---
    backend_api  = { name = "doktori/backend-api",  scope = "dev" }
    backend_chat = { name = "doktori/backend-chat", scope = "dev" }
    ai           = { name = "doktori/ai",           scope = "dev" }
    frontend     = { name = "doktori/frontend",     scope = "dev" }
    nginx        = { name = "doktori/nginx",        scope = "dev" }

    # --- prod 전용 ---
    prod_backend_api  = { name = "doktori/prod-backend-api",  scope = "prod" }
    prod_backend_chat = { name = "doktori/prod-backend-chat", scope = "prod" }
    prod_ai           = { name = "doktori/prod-ai",           scope = "prod" }
    prod_frontend     = { name = "doktori/prod-frontend",     scope = "prod" }
  }
}

resource "aws_ecr_repository" "this" {
  for_each = local.repositories

  name                 = each.value.name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(
    {
      Name    = each.value.name
      Service = replace(each.key, "prod_", "")
      Scope   = each.value.scope
    },
    each.value.scope == "prod" ? { Environment = "prod" } : {},
  )
}

resource "aws_ecr_lifecycle_policy" "cleanup" {
  for_each = local.repositories

  repository = aws_ecr_repository.this[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}