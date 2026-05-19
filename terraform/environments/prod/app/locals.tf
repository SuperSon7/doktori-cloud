locals {
  net = {
    vpc_id             = data.terraform_remote_state.base.outputs.networking.vpc_id
    vpc_cidr           = data.terraform_remote_state.base.outputs.networking.vpc_cidr
    subnet_ids         = data.terraform_remote_state.base.outputs.networking.subnet_ids
    internal_zone_id   = data.terraform_remote_state.base.outputs.networking.internal_zone_id
    internal_zone_name = data.terraform_remote_state.base.outputs.networking.internal_zone_name
    mgmt_vpc_cidr      = data.terraform_remote_state.base.outputs.networking.mgmt_vpc_cidr
  }
}

locals {
  frontend_private_subnet_ids = [
    local.net.subnet_ids["private_app"],
    local.net.subnet_ids["private_app_c"],
  ]
  frontend_codedeploy_application_name      = "${var.project_name}-frontend-${var.environment}"
  frontend_codedeploy_deployment_group_name = "${local.frontend_codedeploy_application_name}-asg"

  # control_plane_endpoint는 Route53 CNAME (k8s.prod.doktori.internal → NLB)
  # 모듈 output 참조 시 순환참조 발생하므로 DNS 이름 직접 사용
  k8s_master_user_data = templatefile("${path.module}/templates/k8s_master_user_data.sh.tftpl", {
    region                 = var.aws_region
    project_name           = var.project_name
    environment            = var.environment
    control_plane_endpoint = "k8s.${var.environment}.doktori.internal"
    pod_cidr               = "100.64.0.0/16"
    service_cidr           = "198.18.16.0/20"
    calico_version         = var.calico_version
    gateway_api_version    = var.gateway_api_version
    ngf_version            = var.ngf_version
  })

  k8s_worker_user_data = templatefile("${path.module}/templates/k8s_worker_user_data.sh.tftpl", {
    region       = var.aws_region
    project_name = var.project_name
    environment  = var.environment
  })

  rds_monitoring_user_data = templatefile("${path.module}/templates/rds_monitoring_user_data.sh.tftpl", {
    region               = var.aws_region
    db_host              = coalesce(data.terraform_remote_state.data.outputs.database.proxy_host, data.terraform_remote_state.data.outputs.database.db_host)
    db_port              = data.terraform_remote_state.data.outputs.database.db_port
    db_username          = data.terraform_remote_state.data.outputs.database.db_username
    db_password_ssm_path = data.terraform_remote_state.data.outputs.database.db_password_ssm_path
  })
}

# -----------------------------------------------------------------------------
# Route53 — Internal DNS records
# -----------------------------------------------------------------------------
locals {
  compute_dns_name_map = {
    front          = "front"
    ai             = "ai"
    rds_monitoring = "rds-exporter"
  }
}
