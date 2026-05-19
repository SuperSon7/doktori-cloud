# -----------------------------------------------------------------------------
# GitHub Actions Deploy Role (OIDC)
# -----------------------------------------------------------------------------
locals {
  # Deploy role: 서비스 레포 전용 (be/fe/ai) — ECR push, SSM 배포 용도
  # Cloud 레포는 terraform_oidc_subjects(아래)에서 별도 관리
  github_oidc_subjects = flatten([
    for repo in var.github_repos : [
      "repo:${var.github_org}/${repo}:ref:refs/heads/main",
      "repo:${var.github_org}/${repo}:ref:refs/heads/develop",
      "repo:${var.github_org}/${repo}:ref:refs/heads/staging",
    ]
  ])


  # Terraform role: Cloud 레포 전용 (main, feature/*, PR).
  # GitHub OIDC subject는 owner/repo를 포함하므로 org가 다른 mirror repo를 별도로 허용한다.
  terraform_oidc_subjects = flatten([
    for repo in var.terraform_repos : [
      "repo:${repo.owner}/${repo.repo}:ref:refs/heads/main",
      "repo:${repo.owner}/${repo.repo}:ref:refs/heads/feature/*",
      "repo:${repo.owner}/${repo.repo}:pull_request",
    ]
  ])
}
