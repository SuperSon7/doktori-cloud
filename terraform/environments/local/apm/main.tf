# Artifact generation only. No cloud provider or infrastructure resource.
module "api_apm" {
  source             = "../../../modules/apm-runtime"
  enabled            = true
  environment        = "local"
  service_name       = "doktori-api-pilot"
  otlp_http_endpoint = "http://alloy:4318"
  sample_ratio       = 1
}
output "api_environment" { value = module.api_apm.environment }
output "java_argument" { value = module.api_apm.java_argument }
output "agent_install_script" { value = module.api_apm.install_script }
