# Doktori Monitoring Setup

This repository contains Ansible configurations for setting up a comprehensive monitoring stack using Grafana, Prometheus, Loki, and Promtail.

## Architecture

The setup consists of two main components:
1. **Monitoring Server**: Central server hosting the visualization and data storage services.
2. **Target Servers**: Application servers sending metrics and logs to the monitoring server.

### 1. Monitoring Server
- **Host**: `monitor_node` (43.200.183.8)
- **Role**: `monitoring`
- **Services Installed**:
  - **Grafana** (Port `3000`): Visualization dashboard.
  - **Prometheus** (v2.45.0, Port `9090`): Metrics collection and storage.
  - **Loki** (v2.9.4, Port `3100`): Log aggregation system.

### 2. Target Servers (Agents)
- **Hosts**:
  - `prod_node` (doktori.kr) - Production Environment
  - `dev_node` (dev.doktori.kr) - Development Environment
- **Role**: `agent`
- **Services Installed**:
  - **Node Exporter** (v1.6.1, Port `9100`): Exposes server hardware and OS metrics.
  - **Promtail** (v2.9.4, Port `9080`): Log collector that ships logs to Loki.

## Data Collection

### Metrics (Prometheus)
Prometheus is configured to scrape the following targets every 15 seconds:

1. **System Metrics (`node_metrics`)**:
   - Scraped from Node Exporter running on port `9100` on both Prod and Dev servers.
   - Labels: `env: prod` or `env: dev`.

2. **Application Metrics (`spring-boot-app`)**:
   - Scraped from Spring Boot Actuator endpoint (`/api/actuator/prometheus`).
   - Targets: Ports `8080` and `8081` on both Prod and Dev servers.
   - Labels: `env: prod` or `env: dev`.

### Logs (Loki & Promtail)
Promtail collects application logs and pushes them to the Loki server (`http://43.200.183.8:3100`).

- **Log Source**: `/home/ubuntu/app/backend/*.log`
- **Job Name**: `spring-boot-app`
- **Labels**:
  - `env`: Derived from inventory (`prod` or `dev`).
  - `instance`: Hostname of the target server.

## Configuration Details

### Inventory (`inventory.ini`)
Defines the hosts and their environment specific variables.
```ini
[monitoring_server]
monitor_node ...

[targets]
prod_node ... env=prod
dev_node ... env=dev
```

### Global Variables (`group_vars/all.yml`)
- `monitoring_server_ip`: 43.200.183.8 (Used by Promtail to locate Loki)

## Usage

To apply the configurations, run the Ansible playbook:

```bash
ansible-playbook -i inventory.ini playbook.yml
```

This will:
1. Install and configure Grafana, Prometheus, and Loki on the `monitoring_server`.
2. Install and configure Node Exporter and Promtail on all `targets`.
