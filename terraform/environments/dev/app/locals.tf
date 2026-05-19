locals {
  net = {
    vpc_id             = data.terraform_remote_state.base.outputs.networking.vpc_id
    vpc_cidr           = data.terraform_remote_state.base.outputs.networking.vpc_cidr
    subnet_ids         = data.terraform_remote_state.base.outputs.networking.subnet_ids
    internal_zone_id   = data.terraform_remote_state.base.outputs.networking.internal_zone_id
    internal_zone_name = data.terraform_remote_state.base.outputs.networking.internal_zone_name
  }
  mgmt_vpc_cidr = data.terraform_remote_state.monitoring_base.outputs.vpc_cidr
}

locals {
  batch_instance_key  = "ai_batch"
  qdrant_instance_key = "ai_qdrant"
  batch_log_file      = "/var/log/doktori/weekly-batch.log"
  dev_ai_ami_id       = var.dev_ai_ami_id == "" ? data.aws_ami.dev_app_golden.id : data.aws_ami.dev_ai_golden[0].id
  # var.ssm_parameter_path이 null이면 프로젝트 컨벤션 경로로 자동 계산
  ssm_parameter_path = coalesce(var.ssm_parameter_path, "/${var.project_name}/${var.environment}")
  batch_tag_selector = {
    Environment = var.environment
    Service     = "batch-weekly"
    Schedule    = "weekly"
  }
  batch_image_uri = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.batch_image_repository}:${var.batch_image_tag}"
  batch_user_data = templatefile("${path.module}/templates/dev_ai_batch_user_data.sh.tftpl", {
    aws_region         = var.aws_region
    ecr_registry       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
    image_uri          = local.batch_image_uri
    ssm_parameter_path = local.ssm_parameter_path
    batch_command      = join(" ", [for part in var.batch_container_command : format("%q", part)])
    log_file           = local.batch_log_file
  })
  qdrant_internal_host = "ai-qdrant.${local.net.internal_zone_name}"
  qdrant_user_data = templatefile("${path.module}/templates/dev_qdrant_user_data.sh.tftpl", {
    aws_region         = var.aws_region
    ssm_parameter_path = local.ssm_parameter_path
    qdrant_image       = var.qdrant_image
  })
}

# -----------------------------------------------------------------------------
# Route53 — Internal DNS records
# -----------------------------------------------------------------------------
locals {
  dns_name_map = {
    app       = "app"
    front     = "front"
    ai        = "ai"
    ai_qdrant = "ai-qdrant"
  }
}
