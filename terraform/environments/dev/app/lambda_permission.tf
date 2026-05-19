resource "aws_lambda_permission" "batch_start_scheduler" {
  statement_id  = "AllowExecutionFromEventBridgeScheduler"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.batch_start.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.weekly_batch_start.arn
}
