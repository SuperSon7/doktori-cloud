# =============================================================================
# Prod-equivalent EC2 specs for load/stress testing
# Usage: terraform apply -var-file=../prod-spec.tfvars
#
# SYNC: these values must match prod/app/main.tf
# If prod specs change, update this file accordingly.
# RDS is always prod spec (db.t4g.small) — no scaling needed.
# =============================================================================

instance_types = {
  nginx          = "t4g.micro"
  front          = "t4g.small"
  api            = "t4g.small"
  chat           = "t4g.medium"
  ai             = "t4g.medium"
  rds_monitoring = "t3.micro"
}
default_volume_size = 20
