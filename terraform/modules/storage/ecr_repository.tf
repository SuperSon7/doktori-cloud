# -----------------------------------------------------------------------------
# ECR Repositories (for_each)
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "this" {
  for_each = var.ecr_repositories

  name                 = each.value.name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name    = each.value.name
    Service = each.key
  }
}
