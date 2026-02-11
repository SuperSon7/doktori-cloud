output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.app.id
}

output "instance_private_ip" {
  description = "Private IP address of the EC2 instance"
  value       = aws_instance.app.private_ip
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.app.public_ip
}

output "security_group_id" {
  description = "ID of the application security group"
  value       = aws_security_group.app.id
}

output "ssh_connection" {
  description = "SSH connection command"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_instance.app.public_ip}"
}

output "application_urls" {
  description = "Application URLs"
  value = {
    frontend = "http://${aws_instance.app.public_ip}"
    backend  = "http://${aws_instance.app.public_ip}/api"
    ai       = "http://${aws_instance.app.public_ip}/ai"
    health   = "http://${aws_instance.app.public_ip}/health"
  }
}
