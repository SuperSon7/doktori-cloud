output "compute" {
  description = "Compute outputs"
  value = {
    instance_ids       = module.compute.instance_ids
    private_ips        = module.compute.private_ips
    security_group_ids = module.compute.security_group_ids
    eip_public_ips     = module.compute.eip_public_ips
  }
}

output "app_alb_dns" {
  value = module.frontend.alb_dns_name
}

output "app_alb_internal_fqdn" {
  description = "Internal public app ALB alias. Routes frontend default traffic and /api, /ws to K8s."
  value       = "app-alb.prod.doktori.internal"
}

output "frontend_alb_dns" {
  value = module.frontend.alb_dns_name
}

output "frontend_alb_fqdn" {
  description = "CloudFront → ALB HTTPS origin 도메인. front.doktori.kr ACM 인증서와 쌍으로 동작."
  value       = "front.${var.domain_name}"
}

output "frontend_asg_configuration" {
  value = {
    asg_name                       = module.frontend.asg_name
    target_group_name              = module.frontend.target_group_name
    target_group_arn               = module.frontend.target_group_arn
    launch_template_id             = module.frontend.launch_template_id
    launch_template_name           = module.frontend.launch_template_name
    launch_template_latest_version = module.frontend.launch_template_latest_version
    ami_id                         = module.frontend.ami_id
    subnet_ids                     = module.frontend.private_subnet_ids
    security_group_id              = module.frontend.instance_sg_id
    iam_instance_profile_name      = module.frontend.iam_instance_profile_name
  }
}


output "k8s_nlb_dns" {
  value = module.k8s_cluster.nlb_dns_name
}

output "k8s_master_asg" {
  value = module.k8s_cluster.master_asg_name
}

output "k8s_worker_asg" {
  value = module.k8s_cluster.worker_asg_name
}

output "frontend_codedeploy" {
  description = "Production frontend CodeDeploy configuration"
  value = {
    application_name      = aws_codedeploy_app.frontend_prod.name
    deployment_group_name = aws_codedeploy_deployment_group.frontend_prod.deployment_group_name
    service_role_arn      = aws_iam_role.frontend_codedeploy_service.arn
    revision_bucket_name  = data.terraform_remote_state.data.outputs.codedeploy_revisions.bucket
    frontend_asg_name     = module.frontend.asg_name
    target_group_name     = module.frontend.target_group_name
    target_group_arn      = module.frontend.target_group_arn
  }
}

output "frontend_codedeploy_stack_version" {
  description = "CodeDeploy 스택 배선이 바뀔 때 var.codedeploy_stack_version을 올려서 apply를 강제"
  value       = var.codedeploy_stack_version
}
