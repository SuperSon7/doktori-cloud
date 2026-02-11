# -----------------------------------------------------------------------------
# Lightsail Instance - Prod (doctory-mvp-bigbang)
# -----------------------------------------------------------------------------
resource "aws_lightsail_instance" "prod" {
  name              = "doctory-mvp-bigbang"
  availability_zone = "ap-northeast-2a"
  blueprint_id      = "ubuntu_22_04"
  bundle_id         = "medium_3_0"
  key_pair_name     = "doctory-key"

  tags = {
    Environment = "prod"
  }
}

# NOTE: aws_lightsail_static_ip and aws_lightsail_instance_public_ports
# do not support terraform import. Static IP (doctory-static-ip → 3.37.180.158)
# and port configurations are managed outside of Terraform state.

# -----------------------------------------------------------------------------
# Lightsail Instance - Ubuntu-1
# -----------------------------------------------------------------------------
resource "aws_lightsail_instance" "ubuntu1" {
  name              = "Ubuntu-1"
  availability_zone = "ap-northeast-2a"
  blueprint_id      = "ubuntu_24_04"
  bundle_id         = "small_3_0"
  key_pair_name     = "doctory-key"

  tags = {
    Environment = "prod"
  }
}