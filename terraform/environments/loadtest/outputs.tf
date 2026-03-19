output "vpc_id" {
  value = aws_vpc.loadtest.id
}

output "runner_instances" {
  description = "k6 runner EC2 instance details"
  value = [
    for i, inst in aws_instance.runner : {
      name        = "${var.project_name}-k6-runner-${i + 1}"
      instance_id = inst.id
      az          = inst.availability_zone
      private_ip  = inst.private_ip
      public_ip   = inst.public_ip
    }
  ]
}

output "ssm_instance_ids" {
  description = "Instance IDs for SSM Session Manager"
  value       = [for inst in aws_instance.runner : inst.id]
}

output "ssm_connect_commands" {
  description = "Quick-connect commands for each runner"
  value = [
    for i, inst in aws_instance.runner :
    "aws ${var.aws_profile != "" ? "--profile ${var.aws_profile} " : ""}ssm start-session --target ${inst.id}"
  ]
}

output "grafana_url" {
  description = "Grafana dashboard URL (runner-1)"
  value       = "http://${aws_instance.runner[0].public_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus URL (runner-1)"
  value       = "http://${aws_instance.runner[0].public_ip}:9090"
}