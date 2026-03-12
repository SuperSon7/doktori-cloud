output "instance_ids" {
  description = "Map of service key to EC2 instance ID"
  value       = { for k, v in aws_instance.this : k => v.id }
}

output "private_ips" {
  description = "Map of service key to EC2 private IP"
  value       = { for k, v in aws_instance.this : k => v.private_ip }
}

output "security_group_ids" {
  description = "Map of service key to security group ID"
  value       = { for k, v in aws_security_group.this : k => v.id }
}

output "eip_public_ips" {
  description = "Map of service key to EIP public IP (only for services with associate_eip)"
  value = merge(
    { for k, v in aws_eip.this : k => v.public_ip },
    { for k, v in data.aws_eip.existing : k => v.public_ip },
  )
}

output "iam_role_name" {
  description = "IAM role name for EC2 instances"
  value       = aws_iam_role.ec2_ssm.name
}

output "iam_instance_profile_name" {
  description = "IAM instance profile name"
  value       = aws_iam_instance_profile.ec2_ssm.name
}
