resource "aws_iam_role_policy" "k8s_worker_asg_self_heal" {
  name = "${var.project_name}-${var.environment}-k8s-worker-asg-self-heal"
  role = module.compute.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetInstanceHealth",
        ]
        Resource = "*"
      },
    ]
  })
}
