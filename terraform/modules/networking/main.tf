# --- moved blocks: 기존 단일 NAT → for_each["primary"]로 무중단 전환 ---
moved {
  from = aws_instance.nat
  to   = aws_instance.nat["primary"]
}

moved {
  from = aws_eip.nat
  to   = aws_eip.nat["primary"]
}

moved {
  from = aws_eip_association.nat
  to   = aws_eip_association.nat["primary"]
}

# --- moved blocks: 기존 단일 route table → for_each["primary"] ---
moved {
  from = aws_route_table.private
  to   = aws_route_table.private["primary"]
}

moved {
  from = aws_route.private_nat
  to   = aws_route.private_nat["primary"]
}
