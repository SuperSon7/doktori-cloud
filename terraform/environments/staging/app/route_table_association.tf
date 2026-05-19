resource "aws_route_table_association" "h_k8s" {
  for_each = aws_subnet.h_k8s

  subnet_id      = each.value.id
  route_table_id = local.net.private_route_table_ids["primary"]
}
