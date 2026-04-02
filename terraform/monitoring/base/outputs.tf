output "vpc_id" {
  description = "mgmt VPC ID"
  value       = aws_vpc.mgmt.id
}

output "vpc_cidr" {
  description = "mgmt VPC CIDR"
  value       = aws_vpc.mgmt.cidr_block
}

output "public_subnet_id" {
  description = "mgmt public subnet ID (NAT/VPN)"
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "mgmt private subnet ID (monitoring EC2)"
  value       = aws_subnet.private.id
}

output "nat_eip" {
  description = "NAT 인스턴스 EIP (WireGuard VPN 엔드포인트, Prometheus 스크레이프 화이트리스트용)"
  value       = aws_eip.nat.public_ip
}

output "public_route_table_id" {
  description = "mgmt public route table ID"
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "mgmt private route table ID"
  value       = aws_route_table.private.id
}

output "mgmt_zone_id" {
  description = "mgmt PHZ zone ID"
  value       = aws_route53_zone.mgmt.zone_id
}

output "mgmt_zone_name" {
  description = "mgmt PHZ zone name"
  value       = aws_route53_zone.mgmt.name
}
