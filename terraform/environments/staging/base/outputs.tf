output "networking" {
  description = "Networking outputs for downstream layers"
  value = {
    vpc_id             = module.networking.vpc_id
    vpc_cidr           = module.networking.vpc_cidr
    subnet_ids         = module.networking.subnet_ids
    nat_sg_id          = module.networking.nat_sg_id
    nat_eip            = module.networking.nat_eip
    vpc_endpoint_sg_id = module.networking.vpc_endpoint_sg_id
  }
}
