resource "aws_ec2_instance_state" "batch_default_stopped" {
  instance_id = module.compute.instance_ids[local.batch_instance_key]
  state       = "stopped"
  force       = false # running 중 apply 시 강제 종료 안 함 — 배치 실행 중 데이터 유실 방지
  depends_on  = [module.compute]
}
