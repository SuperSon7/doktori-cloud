# RDS MySQL Exporter Recovery

## Context

Prod has two separate RDS observability paths:

- RDS Proxy health and pooling metrics are monitored through Grafana's CloudWatch datasource using `AWS/RDS` proxy metrics.
- MySQL engine/internal metrics are collected from a dedicated RDS monitoring EC2 running `mysqld_exporter` on port `9104`.

The RDS Proxy itself was available and actively used by prod app configuration. Live SSM values for `DB_URL` and `AI_DB_URL` pointed at `doktori-prod-proxy.proxy-cp4osckyentj.ap-northeast-2.rds.amazonaws.com`, and CloudWatch showed active proxy client/database connections.

## Problem

The RDS monitoring EC2 was running, but `mysqld_exporter` was crash-looping and `127.0.0.1:9104` was closed. Logs showed:

- `failed to validate config`
- `no user specified in section or parent`
- `Error parsing host config`
- `no configuration found`

Prometheus also had no scrape job for the RDS exporter, so even a healthy exporter would not have been scraped into the existing MySQL Grafana dashboard.

## Decision Log

### Decision 1: Keep RDS Proxy Monitoring on CloudWatch

- Choice: Leave RDS Proxy monitoring on the existing CloudWatch-backed Grafana dashboard.
- Alternatives: Try to point `mysqld_exporter` at the RDS Proxy endpoint.
- Tradeoffs: CloudWatch proxy metrics are less granular than MySQL engine metrics, but they are the native source for proxy-side connection pooling, borrow latency, session pinning, and endpoint health.
- Rationale: RDS Proxy is not a MySQL server observability target. AWS publishes RDS Proxy metrics through `AWS/RDS` dimensions such as `ProxyName`, `EndpointName`, `TargetGroup`, and `TargetRole`.

### Decision 2: Point MySQL Exporter at RDS Directly

- Choice: Configure `mysqld_exporter` against the RDS instance endpoint, not the RDS Proxy endpoint.
- Alternatives: Keep the previous `coalesce(proxy_host, db_host)` behavior and fix proxy auth.
- Tradeoffs: The exporter uses a direct DB connection, so it does not measure the proxy path. Proxy metrics remain covered by CloudWatch.
- Rationale: The RDS Proxy endpoint returned `Access denied` for the exporter connection, while the direct RDS endpoint returned `mysql_up 1` and exposed the dashboard's expected `mysql_global_status_*` metrics.

### Decision 3: Use `my.cnf` Configuration for mysqld_exporter

- Choice: Replace the old `DATA_SOURCE_NAME` environment file with `/etc/mysqld_exporter.cnf` and `--config.my-cnf`.
- Alternatives: Use `--mysqld.address` and `--mysqld.username` flags with `MYSQLD_EXPORTER_PASSWORD`.
- Tradeoffs: A config file is another local secret file to permission correctly, but it matches the exporter's native config format and avoids putting credentials in process arguments.
- Rationale: `mysqld_exporter` 0.15+ removed support for the monolithic `DATA_SOURCE_NAME` environment variable. The installed prod version is `0.15.1`.

## Implementation Summary

- Updated `packer/scripts/rds-monitoring-setup.sh`:
  - creates `/etc/mysqld_exporter.cnf` placeholder instead of `/etc/mysqld_exporter.env`
  - uses `--config.my-cnf=/etc/mysqld_exporter.cnf`
  - waits for `network-online.target`
  - disables startup until user-data writes real DB credentials
  - disables the default `slave_status` collector for MySQL 8.4 compatibility
- Updated `terraform/environments/prod/app/locals.tf`:
  - sends the direct RDS host to RDS monitoring user-data
- Updated `terraform/environments/prod/app/templates/rds_monitoring_user_data.sh.tftpl`:
  - retries SSM password fetch at boot
  - writes the exporter client config file
  - verifies `/metrics` locally after restart
- Updated `monitoring/prometheus/prometheus.yml`:
  - adds `rds-mysql` scrape target `10.1.26.239:9104`
  - labels the target as `env=prod`, `instance=mysql`, `app=mysql`
- Updated monitoring docs to document the new `rds-mysql` pull path.

## Validation

Local checks:

- `bash -n packer/scripts/rds-monitoring-setup.sh`: passed
- `bash -n terraform/environments/prod/app/templates/rds_monitoring_user_data.sh.tftpl`: passed
- `terraform fmt -check -recursive terraform/environments/prod/app packer`: passed
- `terraform -chdir=terraform/environments/prod/app validate`: passed
- `packer validate -syntax-only packer`: passed

Live recovery and verification:

- Patched the running RDS monitoring EC2 through SSM.
- Patched the live monitoring Prometheus config and restarted Prometheus.
- Applied only `module.compute.aws_instance.this["rds_monitoring"]` with Terraform target apply.
- Targeted Terraform plan after apply: no changes for the RDS monitoring instance.
- RDS monitoring EC2:
  - `mysqld_exporter` active
  - `mysql_up 1`
  - `mysql_version_info{version="8.4.8"} 1`
- Prometheus:
  - `rds-mysql` target health: `up`
  - `up{job="rds-mysql"} = 1`
  - `mysql_up{job="rds-mysql"} = 1`

Known unrelated pending changes visible in `prod/app` plan were not applied:

- `aws_iam_role_policy.k8s_worker_asg_self_heal`
- frontend ASG capacity changes
- K8s ASG capacity changes
- K8s worker launch template user-data changes

## Follow-ups

- Confirm whether RDS Proxy secret rotation/update is needed. Proxy metrics show active production usage, but the exporter could not authenticate through the proxy while it could authenticate directly to RDS.
- Consider replacing the static Prometheus target IP with DNS if the monitoring VPC can resolve `rds-exporter.prod.doktori.internal`, or explicitly manage a PHZ association if cross-VPC DNS is desired.
- Add Grafana alerts for `up{job="rds-mysql"} == 0` and `mysql_up{job="rds-mysql"} == 0` if they are not already covered.

## Retrospective

The failure was a two-part wiring issue: exporter configuration was incompatible with the installed exporter version, and Prometheus did not scrape the exporter at all. Separating proxy metrics from MySQL engine metrics kept the fix narrow and avoided changing the production app's RDS Proxy path.
