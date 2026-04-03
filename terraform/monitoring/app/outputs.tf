output "instance_id" {
  description = "Monitoring EC2 instance ID"
  value       = aws_instance.monitoring.id
}

output "private_ip" {
  description = "Monitoring EC2 private IP"
  value       = aws_instance.monitoring.private_ip
}

output "ami_id" {
  description = "AMI ID"
  value       = data.aws_ami.ubuntu.id
}

output "ami_name" {
  description = "AMI name (Ubuntu version + architecture)"
  value       = data.aws_ami.ubuntu.name
}
