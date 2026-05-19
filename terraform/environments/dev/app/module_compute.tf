module "compute" {
  source = "../../../modules/compute"

  project_name           = var.project_name
  environment            = var.environment
  aws_region             = var.aws_region
  vpc_id                 = local.net.vpc_id
  vpc_cidr               = local.net.vpc_cidr
  enable_batch_self_stop = true
  subnet_ids             = local.net.subnet_ids
  key_name               = var.key_name

  s3_bucket_arns = [
    data.terraform_remote_state.data.outputs.storage.bucket_arns["app"],
  ]

  ssm_parameter_paths = [
    local.ssm_parameter_path,
  ]

  services = {
    app = {
      ami_id        = data.aws_ami.dev_app_golden.id
      instance_type = var.app_instance_type
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = 60
      associate_eip = false
      tags = {
        Owner    = "cloud"
        Service  = "app"
        AutoStop = "true"
      }
      sg_ingress = [
        { description = "from internet to dev HTTP", from_port = 80, to_port = 80, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "from internet to dev HTTPS", from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "from dev VPC to frontend app port", from_port = 3000, to_port = 3000, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "from dev VPC to API app port", from_port = 8080, to_port = 8080, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "from dev VPC to AI service port", from_port = 8000, to_port = 8000, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "from dev VPC to MySQL", from_port = 3306, to_port = 3306, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "from dev VPC to MongoDB", from_port = 27017, to_port = 27017, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "from internet to WireMock", from_port = 9090, to_port = 9090, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
        { description = "from dev or mgmt VPC to RabbitMQ management", from_port = 15672, to_port = 15672, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr, local.mgmt_vpc_cidr] },
        { description = "from dev VPC to Redis", from_port = 6379, to_port = 6379, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
      ]
    }
    front = {
      ami_id        = data.aws_ami.frontend_golden.id
      instance_type = var.front_instance_type
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = 30
      associate_eip = false
      tags = {
        Owner    = "fe"
        AutoStop = "true"
        Service  = "front"
      }
      sg_ingress = [
        { description = "from dev VPC to frontend app port", from_port = 3000, to_port = 3000, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
      ]
    }
    ai = {
      ami_id        = local.dev_ai_ami_id
      instance_type = var.ai_instance_type
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = 30
      tags = {
        Owner    = "ai"
        AutoStop = "true"
        Service  = "ai"
      }
      sg_ingress = [] # AI port(8000)는 app SG에서 cross-rule로 허용
    }
    (local.qdrant_instance_key) = {
      ami_id        = local.dev_ai_ami_id
      instance_type = var.qdrant_instance_type
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = var.qdrant_volume_size
      user_data     = local.qdrant_user_data
      tags = {
        Owner    = "ai"
        AutoStop = "false"
        Service  = "ai-qdrant"
      }
      sg_ingress = [
        { description = "Qdrant HTTP from VPC", from_port = 6333, to_port = 6333, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
        { description = "Qdrant gRPC from VPC", from_port = 6334, to_port = 6334, protocol = "tcp", cidr_blocks = [local.net.vpc_cidr] },
      ]
    }
    (local.batch_instance_key) = {
      ami_id        = local.dev_ai_ami_id
      instance_type = var.batch_instance_type
      architecture  = "arm64"
      subnet_key    = "private_app"
      volume_size   = var.batch_volume_size
      user_data     = local.batch_user_data
      tags = {
        Owner    = "ai"
        AutoStop = "true"
        Service  = "ai-batch"
        Schedule = local.batch_tag_selector.Schedule
      }
      sg_ingress = []
    }
  }

  sg_cross_rules = [
    { service_key = "ai", source_key = "app", from_port = 8000, to_port = 8000, protocol = "tcp" },
    { service_key = local.qdrant_instance_key, source_key = "ai", from_port = 6333, to_port = 6333, protocol = "tcp" },
    { service_key = local.qdrant_instance_key, source_key = local.batch_instance_key, from_port = 6333, to_port = 6333, protocol = "tcp" },
  ]
}
