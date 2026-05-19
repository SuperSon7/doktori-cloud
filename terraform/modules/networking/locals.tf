locals {
  nat_instances = var.nat_instances != null ? var.nat_instances : {
    primary = { subnet_key = var.nat_subnet_key }
  }

  # Map each private subnet to its NAT key based on az_key
  # Falls back to "primary" if no NAT exists for that AZ
  subnet_nat_key = {
    for k, v in var.subnets : k =>
    v.tier == "public" ? null :
    contains(keys(local.nat_instances), v.az_key) ? v.az_key : "primary"
  }
}

locals {
  nat_instance_profile = var.nat_iam_instance_profile != "" ? var.nat_iam_instance_profile : (
    length(aws_iam_instance_profile.nat) > 0 ? aws_iam_instance_profile.nat[0].name : null
  )
}
