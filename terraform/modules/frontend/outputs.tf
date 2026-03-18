output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID (for Route53 alias)"
  value       = aws_lb.this.zone_id
}

output "alb_arn" {
  value = aws_lb.this.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.this.arn
}

output "target_group_name" {
  value = aws_lb_target_group.this.name
}

output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "instance_sg_id" {
  value = aws_security_group.instance.id
}

output "asg_name" {
  value = aws_autoscaling_group.this.name
}

output "launch_template_id" {
  value = aws_launch_template.this.id
}

output "launch_template_name" {
  value = aws_launch_template.this.name
}

output "launch_template_latest_version" {
  value = aws_launch_template.this.latest_version
}

output "ami_id" {
  value = local.ami_id
}

output "private_subnet_ids" {
  value = var.private_subnet_ids
}

output "iam_instance_profile_name" {
  value = var.iam_instance_profile_name
}

output "http_listener_arn" {
  description = "HTTP listener ARN (for adding path-based rules)"
  value       = aws_lb_listener.http.arn
}
