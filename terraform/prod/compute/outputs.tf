output "nginx_instance_id" {
  description = "Nginx EC2 instance ID"
  value       = aws_instance.nginx.id
}

output "nginx_eip" {
  description = "Nginx Elastic IP"
  value       = aws_eip.nginx.public_ip
}

output "front_instance_id" {
  description = "Frontend EC2 instance ID"
  value       = aws_instance.front.id
}

output "front_private_ip" {
  description = "Frontend EC2 private IP"
  value       = aws_instance.front.private_ip
}

output "api_instance_id" {
  description = "API EC2 instance ID"
  value       = aws_instance.api.id
}

output "api_private_ip" {
  description = "API EC2 private IP"
  value       = aws_instance.api.private_ip
}

output "chat_instance_id" {
  description = "Chat EC2 instance ID"
  value       = aws_instance.chat.id
}

output "chat_private_ip" {
  description = "Chat EC2 private IP"
  value       = aws_instance.chat.private_ip
}

output "ai_instance_id" {
  description = "AI EC2 instance ID"
  value       = aws_instance.ai.id
}

output "ai_private_ip" {
  description = "AI EC2 private IP"
  value       = aws_instance.ai.private_ip
}

output "nginx_sg_id" {
  description = "Nginx security group ID"
  value       = aws_security_group.nginx.id
}

output "api_sg_id" {
  description = "API security group ID"
  value       = aws_security_group.api.id
}

output "db_sg_id" {
  description = "DB security group ID"
  value       = aws_security_group.db.id
}
