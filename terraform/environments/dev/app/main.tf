# =============================================================================
# Dev App Layer — compute (dev-app + dev-ai 인스턴스)
# =============================================================================

data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.environment}/base/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_caller_identity" "current" {}

data "archive_file" "batch_start_lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/start_tagged_instances.py"
  output_path = "${path.module}/lambda/start_tagged_instances.zip"
}

locals {
  net                = data.terraform_remote_state.base.outputs.networking
  batch_instance_key = "dev_ai_batch"
  batch_log_file     = "/var/log/doktori/weekly-batch.log"
  batch_tag_selector = {
    Environment = "dev"
    Role        = "batch-weekly"
    Schedule    = "weekly"
  }
  batch_image_uri = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.batch_image_repository}:${var.batch_image_tag}"
  batch_user_data = templatefile("${path.module}/templates/dev_ai_batch_user_data.sh.tftpl", {
    aws_region         = var.aws_region
    ecr_registry       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
    image_uri          = local.batch_image_uri
    ssm_parameter_path = var.batch_ssm_parameter_path
    batch_command      = join(" ", [for part in var.batch_container_command : format("%q", part)])
    log_file           = local.batch_log_file
  })
}

# -----------------------------------------------------------------------------
# Route53 — Internal DNS records
# -----------------------------------------------------------------------------
locals {
  dns_name_map = {
    dev_app = "app"
    dev_ai  = "ai"
  }
}

resource "aws_route53_record" "service" {
  for_each = local.dns_name_map

  zone_id = local.net.internal_zone_id
  name    = "${each.value}.${local.net.internal_zone_name}"
  type    = "A"
  ttl     = 300
  records = [module.compute.private_ips[each.key]]
}

module "compute" {
  source = "../../../modules/compute"

  project_name          = var.project_name
  environment           = var.environment
  aws_region            = var.aws_region
  vpc_id                = local.net.vpc_id
  vpc_cidr              = local.net.vpc_cidr
  enable_batch_self_stop = true
  subnet_ids   = local.net.subnet_ids
  key_name     = var.key_name

  s3_bucket_arns = [
    "arn:aws:s3:::${var.project_name}-v2-${var.environment}",
    "arn:aws:s3:::${var.project_name}-v2-dev",
  ]

  ssm_parameter_paths = [
    "/${var.project_name}/${var.environment}",
    "/${var.project_name}/dev",
  ]

  services = {
    dev_app = {
      instance_type = "t4g.medium"
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = 60
      associate_eip = false
      tags = {
        Part        = "cloud"
        Environment = "dev"
        Service     = "app"
        AutoStop    = "true"
      }
      sg_ingress = [
        { description = "HTTP", from_port = 80, to_port = 80, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "HTTPS", from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "Frontend from VPC", from_port = 3000, to_port = 3000, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "Backend from VPC", from_port = 8080, to_port = 8080, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "AI service from VPC", from_port = 8000, to_port = 8000, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "MySQL from VPC", from_port = 3306, to_port = 3306, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "SSH", from_port = 22, to_port = 22, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "MySQL from prod VPC", from_port = 3306, to_port = 3306, protocol = "tcp", cidr_blocks = ["10.1.0.0/16"] },
        { description = "RDS replication source", from_port = 3306, to_port = 3306, protocol = "tcp", cidr_blocks = ["15.164.45.30/32"] },
        { description = "Wiremock", from_port = 9090, to_port = 9090, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "RabbitMQ Management", from_port = 15672, to_port = 15672, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "Redis from VPC", from_port = 6379, to_port = 6379, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
      ]
    }
    dev_ai = {
      instance_type = "t4g.medium"
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = 30
      tags = {
        Part        = "ai"
        Environment = "dev"
        AutoStop    = "true"
        Service     = "ai"
      }
      sg_ingress = [] # AI port(8000)는 dev_app SG에서 cross-rule로 허용
    }
    (local.batch_instance_key) = {
      instance_type = var.batch_instance_type
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = var.batch_volume_size
      user_data     = local.batch_user_data
      tags = {
        Part             = "ai"
        Environment      = "dev"
        AutoStop         = "true"
        Service          = "ai-batch"
        Role             = local.batch_tag_selector.Role
        Schedule         = local.batch_tag_selector.Schedule
        BatchType        = "weekly"
        BatchCommand     = join(" ", var.batch_container_command)
        BatchLogFile     = local.batch_log_file
        StartScheduleKST = "MON 03:00"
      }
      sg_ingress = []
    }
  }

  sg_cross_rules = [
    { service_key = "dev_ai", source_key = "dev_app", from_port = 8000, to_port = 8000, protocol = "tcp" },
  ]
}

resource "aws_ec2_instance_state" "batch_default_stopped" {
  instance_id = module.compute.instance_ids[local.batch_instance_key]
  state       = "stopped"
  force       = false
  depends_on  = [module.compute]
}

resource "aws_cloudwatch_log_group" "batch_start_lambda" {
  name              = "/aws/lambda/${var.project_name}-${var.environment}-start-weekly-batch"
  retention_in_days = 14
}

resource "aws_iam_role" "batch_start_lambda" {
  name = "${var.project_name}-${var.environment}-start-weekly-batch-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "batch_start_lambda" {
  name = "${var.project_name}-${var.environment}-start-weekly-batch"
  role = aws_iam_role.batch_start_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:StartInstances",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.batch_start_lambda.arn}:*"
      },
    ]
  })
}

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
      TAG_Role        = local.batch_tag_selector.Role
      TAG_Schedule    = local.batch_tag_selector.Schedule
    }
  }

  depends_on = [aws_cloudwatch_log_group.batch_start_lambda]
}

resource "aws_iam_role" "batch_start_scheduler" {
  name = "${var.project_name}-${var.environment}-weekly-batch-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "batch_start_scheduler" {
  name = "${var.project_name}-${var.environment}-weekly-batch-scheduler"
  role = aws_iam_role.batch_start_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.batch_start.arn
      },
    ]
  })
}

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

resource "aws_lambda_permission" "batch_start_scheduler" {
  statement_id  = "AllowExecutionFromEventBridgeScheduler"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.batch_start.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.weekly_batch_start.arn
}
