resource "aws_codedeploy_deployment_group" "frontend_prod" {
  app_name              = aws_codedeploy_app.frontend_prod.name
  deployment_group_name = local.frontend_codedeploy_deployment_group_name
  service_role_arn      = aws_iam_role.frontend_codedeploy_service.arn
  tags = {
    Name    = local.frontend_codedeploy_deployment_group_name
    Service = "codedeploy"
  }
  autoscaling_groups     = [module.frontend.asg_name]
  deployment_config_name = "CodeDeployDefault.HalfAtATime"

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "IN_PLACE"
  }

  load_balancer_info {
    target_group_info {
      name = module.frontend.target_group_name
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM", "DEPLOYMENT_STOP_ON_REQUEST"]
  }

  depends_on = [
    aws_iam_role_policy_attachment.frontend_codedeploy_service,
  ]
}
