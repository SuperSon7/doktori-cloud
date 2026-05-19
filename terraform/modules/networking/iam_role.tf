# --- NAT Instance IAM (SSM access) ---
resource "aws_iam_role" "nat" {
  count = var.nat_iam_instance_profile == "" ? 1 : 0

  name = "${var.project_name}-${var.environment}-nat-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.project_name}-${var.environment}-nat-role" }
}
