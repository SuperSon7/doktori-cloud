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
  description = "Private DB subnet ID"
  value       = aws_subnet.private_db.id
}

output "nat_public_ip" {
  description = "NAT Instance public IP (모니터링 서버 SG의 target_server_cidrs에 사용)"
  value       = aws_eip.nat.public_ip
}

output "nat_instance_id" {
  description = "NAT Instance ID"
  value       = aws_instance.nat.id
}
