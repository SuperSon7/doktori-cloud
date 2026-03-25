# Data HA Module — Redis Sentinel + RabbitMQ Quorum Queue

## Architecture

```
                    ┌─────── AZ-a ────────┐  ┌─────── AZ-c ────────┐  ┌─────── AZ-b ────────┐
                    │                     │  │                     │  │                     │
                    │  ASG (min=1,max=1)  │  │  ASG (min=1,max=1)  │  │  ASG (min=1,max=1)  │
                    │  ┌───────────────┐  │  │  ┌───────────────┐  │  │  ┌───────────────┐  │
                    │  │   data-1      │  │  │  │   data-2      │  │  │  │   data-3      │  │
                    │  │               │  │  │  │               │  │  │  │               │  │
                    │  │ Redis Primary │  │  │  │ Redis Replica │  │  │  │ Redis Replica │  │
                    │  │ Sentinel      │  │  │  │ Sentinel      │  │  │  │ Sentinel      │  │
                    │  │ RabbitMQ      │  │  │  │ RabbitMQ      │  │  │  │ RabbitMQ      │  │
                    │  └───────────────┘  │  │  └───────────────┘  │  │  └───────────────┘  │
                    │                     │  │                     │  │                     │
                    └─────────────────────┘  └─────────────────────┘  └─────────────────────┘

                    DNS: data-1.{env}.doktori.internal   data-2.{env}...         data-3.{env}...
                          (Route53 Private Zone, TTL=10s, self-registered on boot)
```

## Self-Healing Flow

```
EC2 dies (hardware failure, OOM, etc.)
  ↓
ASG health check fails (5min grace period)
  ↓
ASG terminates unhealthy instance
  ↓
ASG launches new instance (same Launch Template, same AZ)
  ↓
User Data runs:
  1. hostnamectl set-hostname data-N
  2. Route53 UPSERT → data-N.env.doktori.internal → new IP
  3. Install Docker + fetch SSM credentials
  4. Generate redis.conf, sentinel.conf, rabbitmq.conf
  5. docker compose up -d
  6. Redis: Sentinel detects new node → auto-reconfigures topology
  7. RabbitMQ: join_cluster → Raft replays missed data
  ↓
Cluster fully operational (typically < 5 minutes)
```

## Redis HA

| Component | Role |
|-----------|------|
| **Redis Primary** | Handles reads + writes |
| **Redis Replica ×2** | Async replication, read offloading, failover candidates |
| **Sentinel ×3** | Monitors Primary, quorum-based failover (2/3 agreement) |

**Key Settings:**
- `min-replicas-to-write 1` — Primary rejects writes if no healthy replica (split-brain prevention)
- `min-replicas-max-lag 10` — Replica must ack within 10 seconds
- `sentinel down-after-milliseconds 5000` — 5s before failure detection starts
- `sentinel resolve-hostnames yes` — DNS-based discovery (works with dynamic IPs)
- `appendfsync everysec` — Max ~1s data loss on crash

**Failover Timeline:**
```
T=0s    Primary goes down
T=5s    Sentinel SDOWN (subjective down)
T=5-6s  ODOWN (2/3 Sentinels agree)
T=6-8s  Leader election + Replica promotion
T=8-10s Clients reconnect to new Primary
```

## RabbitMQ HA

| Component | Role |
|-----------|------|
| **Quorum Queue** | Raft-based replication across 3 nodes |
| **pause_minority** | Minority partition stops accepting writes (no split-brain) |
| **Publisher Confirm** | Ack only after majority disk write |

**Key Settings:**
- `default_queue_type = quorum` — All new queues are Quorum Queues
- `cluster_partition_handling = pause_minority` — Safe partition handling
- `vm_memory_high_watermark.relative = 0.4` — Publisher throttle at 40% RAM

## Prerequisites

### SSM Parameters (create before terraform apply)

```bash
ENV=staging
aws ssm put-parameter --name "/doktori/$ENV/REDIS_PASSWORD" \
  --value "YOUR_REDIS_PASSWORD" --type SecureString --region ap-northeast-2

aws ssm put-parameter --name "/doktori/$ENV/RABBITMQ_ERLANG_COOKIE" \
  --value "$(openssl rand -hex 32)" --type SecureString --region ap-northeast-2

# These should already exist:
# /doktori/$ENV/SPRING_RABBITMQ_USERNAME
# /doktori/$ENV/SPRING_RABBITMQ_PASSWORD
```

## Usage

```hcl
module "data_ha" {
  source = "../../../modules/data-ha"

  project_name = "doktori"
  environment  = "staging"
  aws_region   = "ap-northeast-2"

  vpc_id   = module.networking.vpc_id
  vpc_cidr = module.networking.vpc_cidr
  subnet_ids = [
    module.networking.subnet_ids["private_db"],   # AZ-a
    module.networking.subnet_ids["private_rds"],   # AZ-c
    aws_subnet.data_ha_b.id,                       # AZ-b
  ]

  internal_zone_id = module.networking.internal_zone_id
  internal_domain  = module.networking.internal_zone_name

  redis_password_ssm  = "/doktori/staging/REDIS_PASSWORD"
  rabbitmq_user_ssm   = "/doktori/staging/SPRING_RABBITMQ_USERNAME"
  rabbitmq_pass_ssm   = "/doktori/staging/SPRING_RABBITMQ_PASSWORD"
  rabbitmq_cookie_ssm = "/doktori/staging/RABBITMQ_ERLANG_COOKIE"
}
```

## Spring Boot Application Config

### Redis (Sentinel mode)

```yaml
spring:
  data:
    redis:
      sentinel:
        master: mymaster
        nodes: data-1.staging.doktori.internal:26379,data-2.staging.doktori.internal:26379,data-3.staging.doktori.internal:26379
      password: ${REDIS_PASSWORD}
      timeout: 5000ms
      lettuce:
        pool:
          max-active: 20
          max-idle: 10
          min-idle: 5
        shutdown-timeout: 200ms
```

### RabbitMQ (cluster addresses)

```yaml
spring:
  rabbitmq:
    addresses: data-1.staging.doktori.internal:5672,data-2.staging.doktori.internal:5672,data-3.staging.doktori.internal:5672
    username: ${SPRING_RABBITMQ_USERNAME}
    password: ${SPRING_RABBITMQ_PASSWORD}
    publisher-confirm-type: correlated
    publisher-returns: true
    template:
      mandatory: true
    listener:
      simple:
        acknowledge-mode: manual
        prefetch: 20
```

## Monitoring

Each node exposes Prometheus metrics:
- **Redis**: port 9121 (redis_exporter, needs separate container)
- **RabbitMQ**: port 15692 (built-in prometheus plugin)

Add to Prometheus scrape config:
```yaml
- job_name: 'redis-ha'
  dns_sd_configs:
    - names: ['data-1.staging.doktori.internal', 'data-2.staging.doktori.internal', 'data-3.staging.doktori.internal']
      type: A
      port: 9121

- job_name: 'rabbitmq-ha'
  dns_sd_configs:
    - names: ['data-1.staging.doktori.internal', 'data-2.staging.doktori.internal', 'data-3.staging.doktori.internal']
      type: A
      port: 15692
```

## Fault Injection Testing

After deployment, validate HA with these tests:

| Test | Command | Expected Result |
|------|---------|-----------------|
| Redis Primary kill | `docker stop redis` on data-1 | Sentinel promotes replica in 5-15s |
| Redis Sentinel kill | `docker stop sentinel` on data-1 | 2/3 Sentinels still form quorum |
| RabbitMQ node kill | `docker stop rabbitmq` on data-2 | Quorum Queue continues on 2/3 nodes |
| Network partition | `iptables -A INPUT -s <peer-ip> -j DROP` | Redis: min-replicas-to-write blocks writes on isolated node. RabbitMQ: pause_minority stops minority side |
| ASG self-heal | Terminate EC2 via console | ASG creates new instance, User Data runs, cluster rejoins |

## Cost

| Component | Count | Type | Monthly Cost |
|-----------|-------|------|-------------|
| EC2 | 3 | t4g.small | ~$39 |
| EBS | 3 × 20GB | gp3 | ~$5 |
| Route53 | 3 records | Private Zone | ~$0 |
| **Total** | | | **~$44/month** |