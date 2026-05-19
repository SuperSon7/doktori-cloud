# -----------------------------------------------------------------------------
# Security Groups (for_each)
# -----------------------------------------------------------------------------
resource "aws_security_group" "this" {
  for_each = var.services

  name_prefix = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}-"
  description = "${each.key} service security group"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = each.value.sg_ingress
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
    }
  }

  egress {
    description = "from ${each.key} service to outbound destinations"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.environment}-${replace(each.key, "_", "-")}-sg"
    Service = each.key
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [description]
  }
}
