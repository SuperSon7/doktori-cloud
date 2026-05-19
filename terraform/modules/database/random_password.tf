# -----------------------------------------------------------------------------
# DB Password (random → SSM Parameter Store)
# -----------------------------------------------------------------------------
resource "random_password" "db" {
  length  = 20
  special = false
}
