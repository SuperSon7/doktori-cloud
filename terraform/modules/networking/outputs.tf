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
  description = "NAT instance ID"
  value       = aws_instance.nat.id
}

output "nat_eip" {
  description = "NAT instance public IP"
  value       = aws_eip.nat.public_ip
}

output "nat_sg_id" {
  description = "NAT security group ID"
  value       = aws_security_group.nat.id
}

output "vpc_endpoint_sg_id" {
  description = "VPC Endpoints security group ID (empty string if no interface endpoints)"
  value       = length(aws_security_group.vpc_endpoints) > 0 ? aws_security_group.vpc_endpoints[0].id : ""
}
