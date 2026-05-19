resource "aws_autoscaling_attachment" "worker_alb" {
  autoscaling_group_name = module.k8s_cluster.worker_asg_name
  lb_target_group_arn    = aws_lb_target_group.k8s_backend.arn
}
