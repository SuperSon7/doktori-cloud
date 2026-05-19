resource "aws_lambda_function" "batch_start" {
  function_name    = "${var.project_name}-${var.environment}-start-weekly-batch"
  role             = aws_iam_role.batch_start_lambda.arn
  filename         = data.archive_file.batch_start_lambda.output_path
  source_code_hash = data.archive_file.batch_start_lambda.output_base64sha256
  handler          = "start_tagged_instances.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30

  environment {
    variables = {
      TAG_Environment = local.batch_tag_selector.Environment
      TAG_Service     = local.batch_tag_selector.Service
      TAG_Schedule    = local.batch_tag_selector.Schedule
    }
  }

  depends_on = [aws_cloudwatch_log_group.batch_start_lambda]
}
