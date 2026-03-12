output "compute" {
  description = "Compute outputs"
  value = {
    instance_ids       = module.compute.instance_ids
    private_ips        = module.compute.private_ips
    security_group_ids = module.compute.security_group_ids
    eip_public_ips     = module.compute.eip_public_ips
  }
}

output "chat_observer_public_ip" {
  description = "Public IP for the doktori-chat-observer instance"
  value       = try(module.compute.eip_public_ips["chat_observer"], null)
}
