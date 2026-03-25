# =============================================================================
# Data HA Module — IAM
# SSM + Route53 + ECR permissions for self-healing ASG nodes
# =============================================================================

resource "aws_iam_role" "data_ha" {
  name = "${var.project_name}-${var.environment}-data-ha"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.extra_tags, {
    Name = "${var.project_name}-${var.environment}-data-ha-role"
  })
}

# --- SSM Agent ---
resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.data_ha.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# --- SSM Parameter Store (read credentials) ---
resource "aws_iam_role_policy" "ssm_parameters" {
  name = "ssm-parameters"
  role = aws_iam_role.data_ha.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "arn:aws:kms:${var.aws_region}:*:key/*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com"
          }
        }
      },
    ]
  })
}

# --- Route53 (self-register DNS on boot) ---
resource "aws_iam_role_policy" "route53_update" {
  name = "route53-dns-update"
  role = aws_iam_role.data_ha.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "route53:ChangeResourceRecordSets",
        "route53:GetHostedZone",
      ]
      Resource = "arn:aws:route53:::hostedzone/${var.internal_zone_id}"
    }]
  })
}

# --- ECR (pull Docker images, future use) ---
resource "aws_iam_role_policy" "ecr_pull" {
  name = "ecr-pull"
  role = aws_iam_role.data_ha.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:*:repository/${var.project_name}/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "data_ha" {
  name = "${var.project_name}-${var.environment}-data-ha"
  role = aws_iam_role.data_ha.name
}