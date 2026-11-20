run "disabled" {
 command = plan
 assert {
   condition = length(output.environment) == 0 && output.java_argument == "" && output.install_script == ""
   error_message = "Disabled must emit no runtime changes."
 }
}
run "enabled" {
 command = plan
 variables { enabled = true }
 assert {
   condition = output.environment["OTEL_TRACES_SAMPLER"] == "parentbased_traceidratio" && output.environment["OTEL_LOGS_EXPORTER"] == "none" && strcontains(output.install_script, "sha256sum --check")
   error_message = "Keep bounded sampling, single log pipeline, and checked agent installation."
 }
}
run "invalid_ratio" {
 command = plan
 variables { sample_ratio = 1.1 }
 expect_failures = [var.sample_ratio]
}
run "credential_in_endpoint" {
 command = plan
 variables { otlp_http_endpoint = "http://user:secret@collector:4318" }
 expect_failures = [var.otlp_http_endpoint]
}
