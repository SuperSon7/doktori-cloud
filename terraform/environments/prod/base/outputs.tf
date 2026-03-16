output "networking" {
  description = "Networking outputs for downstream layers"
  value = {
    vpc_id             = module.networking.vpc_id
    vpc_cidr           = module.networking.vpc_cidr
    subnet_ids         = module.networking.subnet_ids
    nat_sg_id          = module.networking.nat_sg_id
    nat_eip            = module.networking.nat_eip
    vpc_endpoint_sg_id = module.networking.vpc_endpoint_sg_id
    internal_zone_id        = module.networking.internal_zone_id
    internal_zone_name      = module.networking.internal_zone_name
    public_route_table_id   = module.networking.public_route_table_id
    private_route_table_ids = module.networking.private_route_table_ids
  }
}

output "storage" {
  description = "Storage outputs for downstream layers"
  value = {
    bucket_names = module.storage.bucket_names
    bucket_arns  = module.storage.bucket_arns
  }
}
