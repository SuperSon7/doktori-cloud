output "compute" {
  description = "Compute outputs"
  value = {
    instance_ids       = module.compute.instance_ids
    private_ips        = module.compute.private_ips
    security_group_ids = module.compute.security_group_ids
    eip_public_ips     = module.compute.eip_public_ips
  }
}

output "h_k8s" {
  description = "Learning-purpose h-k8s node outputs"
  value = {
    instance_ids = {
      for name, instance in aws_instance.h_k8s : name => instance.id
    }
    private_ips = {
      for name, instance in aws_instance.h_k8s : name => instance.private_ip
    }
    security_group_ids = {
      master = try(aws_security_group.h_k8s_master[0].id, null)
      worker = try(aws_security_group.h_k8s_worker[0].id, null)
    }
  }
}
