output "runner_instances" {
  description = "k6 runner EC2 instance details"
  value = [
    for name in local.runner_names : {
      name              = name
      instance_id       = aws_instance.runner[name].id
      availability_zone = aws_instance.runner[name].availability_zone
      private_ip        = aws_instance.runner[name].private_ip
      public_ip         = aws_instance.runner[name].public_ip
    }
  ]
}

output "ssm_instance_ids" {
  description = "Instance IDs to use with AWS Systems Manager Session Manager"
  value       = [for name in local.runner_names : aws_instance.runner[name].id]
}

output "ssm_verify_command" {
  description = "AWS CLI command to verify SSM registration after apply"
  value       = "aws --profile doktori-cloud-h --region ${var.aws_region} ssm describe-instance-information --filters Key=ResourceType,Values=EC2Instance"
}
