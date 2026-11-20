# AWS/시크릿 없이 토폴로지 조합을 검사하기 위한 순수 구성 모듈이다.
module "data_topology" {
  source                   = "../../../modules/data-topology"
  networking               = local.net
  enable_data_ha           = var.enable_data_ha
  enable_redis_ha          = var.enable_redis_ha
  enable_rabbitmq_ha       = var.enable_rabbitmq_ha
  enable_mongodb_ha        = var.enable_mongodb_ha
  mongodb_replica_set_name = var.mongodb_replica_set_name
}
