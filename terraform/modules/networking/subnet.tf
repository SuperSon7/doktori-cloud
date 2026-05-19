# -----------------------------------------------------------------------------
# Subnets (for_each)
# -----------------------------------------------------------------------------
resource "aws_subnet" "this" {
  for_each = var.subnets

  vpc_id     = aws_vpc.main.id
  cidr_block = each.value.cidr
  availability_zone = (
    each.value.az_key == "primary" ? var.availability_zone :
    each.value.az_key == "tertiary" ? var.tertiary_availability_zone :
    var.secondary_availability_zone
  )
  map_public_ip_on_launch = each.value.tier == "public"

  tags = {
    Name = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}"
  }
}
