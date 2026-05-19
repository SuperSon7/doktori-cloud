module "compute" {
  source = "../../../modules/compute"

  project_name           = var.project_name
  environment            = var.environment
  aws_region             = var.aws_region
  vpc_id                 = local.net.vpc_id
  enable_batch_self_stop = true
  vpc_cidr               = local.net.vpc_cidr
  subnet_ids             = local.net.subnet_ids
  key_name               = var.key_name
  custom_ami_id          = data.aws_ami.frontend_golden.id

  s3_bucket_arns = [
    data.terraform_remote_state.data.outputs.storage.bucket_arns["app"],
    data.terraform_remote_state.data.outputs.codedeploy_revisions.arn,
  ]

  ssm_parameter_paths = [
    "/${var.project_name}/${var.environment}",
  ]

  services = {
    front = {
      instance_type = "t4g.small"
      architecture  = "arm64"
      subnet_key    = "private_app"
      tags          = { Owner = "fe" }
      sg_ingress    = []
    }
    ai = {
      instance_type = "t4g.medium"
      architecture  = "arm64"
      subnet_key    = "private_app"
      tags          = { Owner = "ai" }
      sg_ingress    = []
    }
    rds_monitoring = {
      instance_type = "t4g.micro"
      architecture  = "arm64"
      ami_id        = data.aws_ami.rds_monitoring_golden.id
      user_data     = local.rds_monitoring_user_data
      # public → private_app 이동: EIP 불필요, 불필요한 공개 노출 제거
      subnet_key = "private_app"
      tags       = { Owner = "monitoring" }
      sg_ingress = [
        { description = "from prod VPC to rds-monitoring mysqld_exporter", from_port = 9104, to_port = 9104, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        # Prometheus scraper가 mgmt VPC(peering)에 있으므로 mgmt CIDR도 허용
        { description = "from mgmt VPC Prometheus to rds-monitoring mysqld_exporter", from_port = 9104, to_port = 9104, protocol = "tcp", cidr_blocks = [local.net.mgmt_vpc_cidr] },
      ]
    }
  }

  sg_cross_rules = []
}
