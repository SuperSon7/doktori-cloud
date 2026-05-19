resource "aws_cloudwatch_log_group" "batch_start_lambda" {
  name              = "/aws/lambda/${var.project_name}-${var.environment}-start-weekly-batch"
  retention_in_days = 14
}
