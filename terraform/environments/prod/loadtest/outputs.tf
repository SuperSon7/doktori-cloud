output "runner_instances" {
  value = [
    for idx, inst in aws_instance.runner : {
      id         = inst.id
      name       = "${var.project_name}-${var.environment}-k6-runner-${idx + 1}"
      private_ip = inst.private_ip
      public_ip  = inst.public_ip
    }
  ]
}
