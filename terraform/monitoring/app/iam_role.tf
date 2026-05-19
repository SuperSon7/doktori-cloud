# -----------------------------------------------------------------------------
# IAM Role (SSM + Loki S3 + CloudWatch)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "monitoring" {
  name = "${var.project_name}-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.project_name}-monitoring-role" }
}
