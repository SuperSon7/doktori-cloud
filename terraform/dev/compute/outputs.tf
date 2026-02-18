output "dev_app_instance_id" {
  description = "Dev app EC2 instance ID"
  value       = aws_instance.dev_app.id
}

output "dev_app_private_ip" {
  description = "Dev app EC2 private IP"
  value       = aws_instance.dev_app.private_ip
}

output "dev_app_sg_id" {
  description = "Dev app security group ID"
  value       = aws_security_group.dev_app.id
}

# monitoring outputs → terraform/monitoring/outputs.tf 로 이동
