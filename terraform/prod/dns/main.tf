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
# Prod DNS Records
# -----------------------------------------------------------------------------
resource "aws_route53_record" "root" {
  zone_id = data.terraform_remote_state.dns_zone.outputs.zone_id
  name    = "doktori.kr"
  type    = "A"
  ttl     = 300
  records = [var.nginx_eip]
}

resource "aws_route53_record" "www" {
  zone_id = data.terraform_remote_state.dns_zone.outputs.zone_id
  name    = "www.doktori.kr"
  type    = "A"
  ttl     = 300
  records = [var.nginx_eip]
}
