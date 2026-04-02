output "zone_id" {
  description = "Route53 Hosted Zone ID"
  value       = aws_route53_zone.main.zone_id
}

output "name_servers" {
  description = "Route53 Hosted Zone name servers (update at domain registrar)"
  value       = aws_route53_zone.main.name_servers
}

output "domain_name" {
  description = "Domain name"
  value       = aws_route53_zone.main.name
}
