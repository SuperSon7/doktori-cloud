resource "aws_iam_role_policy_attachment" "frontend_codedeploy_service" {
  role       = aws_iam_role.frontend_codedeploy_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}
