# -----------------------------------------------------------------------------
# SSM — MongoDB 접속 정보 (data apply 후 Terraform이 직접 write)
# -----------------------------------------------------------------------------
resource "random_password" "mongo_admin" {
  length  = 24
  special = false
}

resource "random_password" "mongo" {
  length  = 24
  special = false
}
