resource "aws_subnet" "h_k8s" {
  for_each = var.create_h_k8s_nodes ? {
    private_k8s_a = {
      cidr = "10.2.48.0/24"
      az   = "ap-northeast-2a"
    }
    private_k8s_b = {
      cidr = "10.2.49.0/24"
      az   = "ap-northeast-2b"
    }
  } : {}

  vpc_id                  = local.net.vpc_id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}"
  }
}
