resource "aws_scheduler_schedule" "weekly_batch_start" {
  name                         = "${var.project_name}-${var.environment}-weekly-batch-start"
  group_name                   = "default"
  state                        = "ENABLED"
  schedule_expression          = "cron(0 3 ? * MON *)"
  schedule_expression_timezone = "Asia/Seoul"
  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.batch_start.arn
    role_arn = aws_iam_role.batch_start_scheduler.arn

    input = jsonencode({
      source = "eventbridge-scheduler"
      job    = "weekly-batch-start"
    })
  }
}
