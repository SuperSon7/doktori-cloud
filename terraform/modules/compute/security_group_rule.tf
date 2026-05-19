# SG cross-rules (inter-SG references — separate resource to avoid inline conflict)
resource "aws_security_group_rule" "cross" {
  for_each = {
    for rule in var.sg_cross_rules :
    "${rule.service_key}-from-${rule.source_key}-${rule.from_port}" => rule
  }

  type                     = "ingress"
  security_group_id        = aws_security_group.this[each.value.service_key].id
  source_security_group_id = aws_security_group.this[each.value.source_key].id
  from_port                = each.value.from_port
  to_port                  = each.value.to_port
  protocol                 = each.value.protocol
  description              = coalesce(each.value.description, "from ${each.value.source_key} SG to ${each.value.service_key} SG")
}
