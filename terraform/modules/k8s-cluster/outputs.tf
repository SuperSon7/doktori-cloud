output "master_sg_id" {
  value = aws_security_group.master.id
}

output "worker_sg_id" {
  value = aws_security_group.worker.id
}

output "master_asg_name" {
  value = aws_autoscaling_group.master.name
}

output "worker_asg_name" {
  value = aws_autoscaling_group.worker.name
}

output "nlb_dns_name" {
  value = aws_lb.nlb.dns_name
}

output "nlb_arn" {
  value = aws_lb.nlb.arn
}

output "worker_target_group_arn" {
  value = aws_lb_target_group.worker_http.arn
}