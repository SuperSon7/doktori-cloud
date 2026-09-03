# -----------------------------------------------------------------------------
# GitHub Actions Deploy Role (OIDC)
# -----------------------------------------------------------------------------
locals {
  # Deploy role: service repos and Cloud deployment workflows.
  # Jobs bound to a GitHub Environment use an environment subject instead of a ref subject.
  github_oidc_subjects = concat(
    flatten([
      for repo in var.deploy_repos : [
        "repo:${repo.owner}/${repo.repo}:ref:refs/heads/main",
        "repo:${repo.owner}/${repo.repo}:ref:refs/heads/develop",
        "repo:${repo.owner}/${repo.repo}:ref:refs/heads/staging",
      ]
    ]),
    flatten([
      for repo in var.deploy_repos : [
        for environment in var.deploy_role_environments :
        "repo:${repo.owner}/${repo.repo}:environment:${environment}"
      ]
    ]),
  )


  # Terraform role: Cloud repo plans plus environment-protected apply jobs.
  terraform_oidc_subjects = concat(
    flatten([
      for repo in var.terraform_repos : [
        "repo:${repo.owner}/${repo.repo}:ref:refs/heads/main",
        "repo:${repo.owner}/${repo.repo}:ref:refs/heads/feature/*",
        "repo:${repo.owner}/${repo.repo}:pull_request",
      ]
    ]),
    flatten([
      for repo in var.terraform_repos : [
        for environment in var.terraform_role_environments :
        "repo:${repo.owner}/${repo.repo}:environment:${environment}"
      ]
    ]),
  )
}
