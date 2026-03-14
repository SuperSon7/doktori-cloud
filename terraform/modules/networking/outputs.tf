output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}

output "subnet_ids" {
  description = "Map of subnet key to subnet ID"
  value       = { for k, v in aws_subnet.this : k => v.id }
}

output "nat_instance_id" {
  description = "Primary NAT instance ID (backwards compat)"
  value       = aws_instance.nat["primary"].id
}

output "nat_eip" {
  description = "Primary NAT instance public IP (backwards compat)"
  value       = aws_eip.nat["primary"].public_ip
}

output "nat_instance_ids" {
  description = "Map of NAT instance IDs per AZ key"
  value       = { for k, v in aws_instance.nat : k => v.id }
}

output "nat_eips" {
  description = "Map of NAT EIPs per AZ key"
  value       = { for k, v in aws_eip.nat : k => v.public_ip }
}

output "nat_sg_id" {
  description = "NAT security group ID"
  value       = aws_security_group.nat.id
}

output "internal_zone_id" {
  description = "Route53 private hosted zone ID"
  value       = aws_route53_zone.internal.zone_id
}

output "internal_zone_name" {
  description = "Route53 private hosted zone name"
  value       = aws_route53_zone.internal.name
}

output "vpc_endpoint_sg_id" {
  description = "VPC Endpoints security group ID (empty string if no interface endpoints)"
  value       = length(aws_security_group.vpc_endpoints) > 0 ? aws_security_group.vpc_endpoints[0].id : ""
}
