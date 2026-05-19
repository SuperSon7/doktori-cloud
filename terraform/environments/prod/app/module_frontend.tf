# =============================================================================
# Public App ALB + Frontend ASG (Multi-AZ)
# =============================================================================
module "frontend" {
  source = "../../../modules/frontend"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = local.net.vpc_id
  vpc_cidr     = local.net.vpc_cidr
  key_name     = var.key_name

  public_subnet_ids = [
    local.net.subnet_ids["public"],
    local.net.subnet_ids["public_c"],
  ]
  private_subnet_ids = local.frontend_private_subnet_ids

  ami_id                    = data.aws_ami.frontend_golden.id
  instance_type             = "t4g.small"
  iam_instance_profile_name = module.compute.iam_instance_profile_name
  desired_capacity          = 2
  min_size                  = 1
  max_size                  = 4
}
