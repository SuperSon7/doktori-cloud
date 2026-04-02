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

resource "aws_ecr_repository" "this" {
  for_each = local.repositories

  name                 = each.value
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name    = each.value
    Service = each.key
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ecr_lifecycle_policy" "cleanup" {
  for_each = local.repositories

  repository = aws_ecr_repository.this[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "prod-* 태그 10개 유지"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["prod-*"]
          countType      = "imageCountMoreThan"
          countNumber    = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "dev-* 태그 10개 유지"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["dev-*"]
          countType      = "imageCountMoreThan"
          countNumber    = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "untagged 1일 후 삭제"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      }
    ]
  })
}