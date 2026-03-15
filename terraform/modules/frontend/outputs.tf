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

output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "instance_sg_id" {
  value = aws_security_group.instance.id
}

output "asg_name" {
  value = aws_autoscaling_group.this.name
}