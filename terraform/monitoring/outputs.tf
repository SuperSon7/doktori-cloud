output "monitoring_instance_id" {
  description = "Monitoring EC2 instance ID"
  value       = aws_instance.monitoring.id
}

output "monitoring_eip" {
  description = "Monitoring server Elastic IP (타겟 서버 SG/설정에서 이 IP 참조)"
  value       = aws_eip.monitoring.public_ip
}

output "monitoring_private_ip" {
  description = "Monitoring server private IP"
  value       = aws_instance.monitoring.private_ip
}

output "monitoring_security_group_id" {
  description = "Monitoring security group ID"
  value       = aws_security_group.monitoring.id
}

output "ami_id" {
  description = "AMI used for the monitoring instance"
  value       = data.aws_ami.ubuntu.id
}

output "ami_name" {
  description = "AMI name (Ubuntu version + architecture)"
  value       = data.aws_ami.ubuntu.name
}
