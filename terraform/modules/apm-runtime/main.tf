terraform {
  required_version = ">= 1.6.0"
}
variable "enabled" {
  type    = bool
  default = false
}
variable "service_name" {
  type    = string
  default = "doktori-api"
  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.service_name))
    error_message = "Use a simple service name."
  }
}
variable "otlp_http_endpoint" {
  type    = string
  default = "http://127.0.0.1:4318"
  validation {
    condition     = can(regex("^https?://[a-zA-Z0-9.-]+:[0-9]+$", var.otlp_http_endpoint))
    error_message = "Use an explicit http(s) host and port; do not embed credentials."
  }
}
variable "sample_ratio" {
  type    = number
  default = 0.1
  validation {
    condition     = var.sample_ratio >= 0 && var.sample_ratio <= 1
    error_message = "Sampling ratio must be in [0, 1]."
  }
}
variable "environment" {
  type    = string
  default = "staging"
  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.environment))
    error_message = "Use a simple environment name."
  }
}
locals {
  # Reuse the locally verified agent version and checksum, never latest.
  agent = jsondecode(file("${path.module}/../../../local/apm/agent.lock.json"))
  environment = var.enabled ? {
    OTEL_SERVICE_NAME                                     = var.service_name
    OTEL_RESOURCE_ATTRIBUTES                              = "deployment.environment.name=${var.environment},service.namespace=doktori"
    OTEL_EXPORTER_OTLP_PROTOCOL                           = "http/protobuf"
    OTEL_EXPORTER_OTLP_ENDPOINT                           = var.otlp_http_endpoint
    OTEL_TRACES_SAMPLER                                   = "parentbased_traceidratio"
    OTEL_TRACES_SAMPLER_ARG                               = tostring(var.sample_ratio)
    OTEL_METRICS_EXPORTER                                 = "none"
    OTEL_LOGS_EXPORTER                                    = "none"
    OTEL_INSTRUMENTATION_JDBC_STATEMENT_SANITIZER_ENABLED = "true"
  } : {}
  # javaagent is appended by the existing launcher; do not overwrite existing JVM flags.
  agent_argument = var.enabled ? "-javaagent:/opt/doktori/otel/opentelemetry-javaagent.jar" : ""
}
output "environment" { value = local.environment }
output "java_argument" { value = local.agent_argument }
output "environment_file" {
  value = join("\n", [for k, v in local.environment : "${k}=${v}"])
}
output "install_script" {
  value = (var.enabled ? <<-SCRIPT
    #!/usr/bin/env bash
    set -euo pipefail
    install -d -m 0755 /opt/doktori/otel
    target=/opt/doktori/otel/opentelemetry-javaagent.jar
    candidate=$(mktemp /opt/doktori/otel/agent.XXXXXX)
    trap 'rm -f "$candidate"' EXIT
    curl --fail --location --proto '=https' --tlsv1.2 '${local.agent.url}' -o "$candidate"
    printf '%s  %s\n' '${local.agent.sha256}' "$candidate" | sha256sum --check -
    chmod 0644 "$candidate"
    mv "$candidate" "$target"
  SCRIPT
  : "")
}
