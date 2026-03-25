output "master_instance_id" {
  value = aws_instance.k8s_master.id
}

output "master_private_ip" {
  value = aws_instance.k8s_master.private_ip
}

output "worker_instance_ids" {
  value = aws_instance.k8s_worker[*].id
}

output "worker_private_ips" {
  value = aws_instance.k8s_worker[*].private_ip
}

output "master_sg_id" {
  value = aws_security_group.k8s_master.id
}

output "worker_sg_id" {
  value = aws_security_group.k8s_worker.id
}

output "nlb_dns_name" {
  value = aws_lb.k8s_nlb.dns_name
}

output "nlb_arn" {
  value = aws_lb.k8s_nlb.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.k8s_http.arn
}

output "middleware_instance_id" {
  value = aws_instance.middleware.id
}

output "middleware_private_ip" {
  value = aws_instance.middleware.private_ip
}
