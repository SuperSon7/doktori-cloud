resource "aws_eip" "nat" {
  # EIP는 WireGuard 같은 고정 진입점이나 외부 API allowlist가 필요한 NAT에만 할당한다.
  # 필요해지면 호출 레이어에서 nat_eip_keys에 해당 NAT key를 추가한다.
  for_each = {
    for key in var.nat_eip_keys : key => local.nat_instances[key]
  }

  domain = "vpc"

  tags = {
    Name = "${var.project_name}-${var.environment}-nat-${each.key}-eip"
  }
}
