# -----------------------------------------------------------------------------
# Remote State References
# -----------------------------------------------------------------------------
data "terraform_remote_state" "dns_zone" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "dns-zone/terraform.tfstate"
    region = var.aws_region
  }
}

# -----------------------------------------------------------------------------
# Dev DNS Records
# -----------------------------------------------------------------------------
resource "aws_route53_record" "dev" {
  zone_id = data.terraform_remote_state.dns_zone.outputs.zone_id
  name    = "dev.doktori.kr"
  type    = "A"
  ttl     = 300
  records = [var.dev_app_ip]
}

resource "aws_route53_record" "monitoring" {
  zone_id = data.terraform_remote_state.dns_zone.outputs.zone_id
  name    = "monitoring.doktori.kr"
  type    = "A"
  ttl     = 300
  records = [var.monitoring_ip]
}
