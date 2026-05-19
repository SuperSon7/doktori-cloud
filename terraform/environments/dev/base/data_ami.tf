# =============================================================================
# Dev Base Layer — networking
# =============================================================================

# Packer-built NAT AMI (IP forwarding + persistent MASQUERADE + SSM)
data "aws_ami" "nat_golden" {
  owners = ["self"]

  filter {
    name   = "image-id"
    values = [var.nat_ami_id]
  }

  filter {
    name   = "tag:AMI_Type"
    values = ["nat"]
  }
}
