output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  value       = aws_cloudfront_distribution.cdn.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID"
  value       = aws_cloudfront_distribution.cdn.id
}

output "cloudfront_hosted_zone_id" {
  description = "CloudFront hosted zone ID used by Route53 alias records"
  value       = "Z2FDTNDATAQYW2"
}

output "certificate_arn" {
  description = "ACM certificate ARN attached to the CloudFront distribution"
  value       = local.certificate_arn
}

output "acm_certificate_dns_validation_records" {
  description = "DNS validation records to create manually when create_acm_certificate is enabled"
  value = var.create_acm_certificate ? [
    for dvo in aws_acm_certificate.dev[0].domain_validation_options : {
      domain_name  = dvo.domain_name
      record_name  = dvo.resource_record_name
      record_type  = dvo.resource_record_type
      record_value = dvo.resource_record_value
    }
  ] : []
}
