data "archive_file" "batch_start_lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/start_tagged_instances.py"
  output_path = "${path.module}/lambda/start_tagged_instances.zip"
}
