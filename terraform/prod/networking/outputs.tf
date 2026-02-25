output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_id" {
  description = "Public subnet ID"
  value       = aws_subnet.public.id
}

output "private_app_subnet_id" {
  description = "Private app subnet ID"
  value       = aws_subnet.private_app.id
}

output "private_db_subnet_id" {
  description = "Private DB subnet ID (ap-northeast-2a)"
  value       = aws_subnet.private_db.id
}

output "private_rds_subnet_id" {
  description = "Private RDS subnet ID (ap-northeast-2c) - RDS subnet group용"
  value       = aws_subnet.private_rds.id
}

output "nat_instance_note" {
  description = "NAT is a t4g.nano instance managed outside Terraform"
  value       = "NAT instance managed externally"
}

output "vpc_endpoint_sg_id" {
  description = "VPC Endpoints security group ID"
  value       = aws_security_group.vpc_endpoints.id
}
