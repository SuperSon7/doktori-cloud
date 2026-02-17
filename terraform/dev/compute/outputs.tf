output "bastion_instance_id" {
  description = "Bastion EC2 instance ID"
  value       = aws_instance.bastion.id
}

output "bastion_public_ip" {
  description = "Bastion EC2 public IP"
  value       = aws_instance.bastion.public_ip
}

output "dev_app_instance_id" {
  description = "Dev app EC2 instance ID"
  value       = aws_instance.dev_app.id
}

output "dev_app_private_ip" {
  description = "Dev app EC2 private IP"
  value       = aws_instance.dev_app.private_ip
}

output "monitoring_instance_id" {
  description = "Monitoring EC2 instance ID"
  value       = aws_instance.monitoring.id
}

output "monitoring_private_ip" {
  description = "Monitoring EC2 private IP"
  value       = aws_instance.monitoring.private_ip
}

output "dev_app_sg_id" {
  description = "Dev app security group ID"
  value       = aws_security_group.dev_app.id
}

output "monitoring_sg_id" {
  description = "Monitoring security group ID"
  value       = aws_security_group.monitoring.id
}
