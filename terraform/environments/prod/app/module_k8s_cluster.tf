# =============================================================================
# K8s Cluster — Master ASG + Worker ASG + Internal NLB (Multi-AZ)
# =============================================================================
module "k8s_cluster" {
  source = "../../../modules/k8s-cluster"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = local.net.vpc_id
  vpc_cidr     = local.net.vpc_cidr
  key_name     = var.key_name

  public_subnet_ids = [
    local.net.subnet_ids["public"],
    local.net.subnet_ids["public_c"],
  ]
  private_subnet_ids = [
    local.net.subnet_ids["private_app"],
    local.net.subnet_ids["private_app_c"],
    local.net.subnet_ids["private_app_b"],
  ]

  ami_id                    = data.aws_ami.k8s_golden.id
  iam_instance_profile_name = module.compute.iam_instance_profile_name

  master_instance_type = "t4g.medium"
  master_desired       = 3
  user_data_master     = local.k8s_master_user_data

  worker_instance_type = "t4g.medium"
  worker_desired       = 4
  worker_min           = 2
  worker_max           = 6
  user_data_worker     = local.k8s_worker_user_data
}
