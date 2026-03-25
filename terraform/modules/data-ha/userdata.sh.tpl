#!/bin/bash
# =============================================================================
# Data HA Node ${node_index}/${node_count} — Bootstrap Script
#
# Co-located services:
#   - Redis (Primary or Replica) + Sentinel (failover)
#   - RabbitMQ (Quorum Queue cluster member)
#
# Self-healing flow:
#   1. Set hostname → 2. Update Route53 DNS → 3. Install Docker
#   4. Fetch SSM credentials → 5. Resolve peers → 6. Generate configs
#   7. Start services → 8. RabbitMQ cluster join
# =============================================================================
set -euo pipefail
exec > >(tee /var/log/data-ha-init.log) 2>&1

NODE_INDEX=${node_index}
NODE_COUNT=${node_count}
ENV="${environment}"
PROJECT="${project_name}"
DOMAIN="${internal_domain}"
ZONE_ID="${hosted_zone_id}"
REGION="${aws_region}"

MY_HOSTNAME="data-$${NODE_INDEX}"
MY_FQDN="$${MY_HOSTNAME}.$${DOMAIN}"

# IMDSv2 token
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
MY_IP=$(curl -s -H "X-aws-ec2-metadata-token: $${TOKEN}" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

echo "============================================"
echo " Data HA Node $${NODE_INDEX} starting"
echo " IP: $${MY_IP}"
echo " FQDN: $${MY_FQDN}"
echo "============================================"

# =============================================================================
# 1. Set hostname
# =============================================================================
hostnamectl set-hostname "$${MY_HOSTNAME}"
echo "$${MY_IP} $${MY_HOSTNAME} $${MY_FQDN}" >> /etc/hosts

# =============================================================================
# 2. Update Route53 — self-register with low TTL
# =============================================================================
aws route53 change-resource-record-sets \
  --hosted-zone-id "$${ZONE_ID}" \
  --region "$${REGION}" \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"$${MY_FQDN}\",
        \"Type\": \"A\",
        \"TTL\": 10,
        \"ResourceRecords\": [{\"Value\": \"$${MY_IP}\"}]
      }
    }]
  }"
echo "[OK] DNS updated: $${MY_FQDN} -> $${MY_IP}"

# =============================================================================
# 3. Install Docker + utilities
# =============================================================================
if ! command -v docker &>/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y docker.io docker-compose-v2 jq dnsutils
  systemctl enable docker
  systemctl start docker
  usermod -aG docker ubuntu
fi
echo "[OK] Docker ready"

# =============================================================================
# 4. Fetch credentials from SSM Parameter Store
# =============================================================================
get_ssm() {
  aws ssm get-parameter \
    --name "$1" --with-decryption \
    --query 'Parameter.Value' --output text \
    --region "$${REGION}" 2>/dev/null || echo "$2"
}

REDIS_PASS=$(get_ssm "${redis_password_ssm}" "changeme-redis")
RABBIT_USER=$(get_ssm "${rabbitmq_user_ssm}" "doktori")
RABBIT_PASS=$(get_ssm "${rabbitmq_pass_ssm}" "changeme-rabbit")

%{ if rabbitmq_cookie_ssm != "" ~}
ERLANG_COOKIE=$(get_ssm "${rabbitmq_cookie_ssm}" "DOKTORI_CLUSTER_SECRET")
%{ else ~}
ERLANG_COOKIE="DOKTORI_CLUSTER_SECRET"
%{ endif ~}

echo "[OK] Credentials fetched"

# =============================================================================
# 5. Resolve peer nodes — add to /etc/hosts for Docker host networking
# =============================================================================
for i in $(seq 1 $${NODE_COUNT}); do
  if [ "$${i}" -ne "$${NODE_INDEX}" ]; then
    PEER_FQDN="data-$${i}.$${DOMAIN}"
    PEER_IP=""
    for attempt in $(seq 1 30); do
      PEER_IP=$(dig +short "$${PEER_FQDN}" 2>/dev/null | head -1)
      if [ -n "$${PEER_IP}" ] && [ "$${PEER_IP}" != ";" ]; then
        echo "$${PEER_IP} data-$${i} $${PEER_FQDN}" >> /etc/hosts
        echo "[OK] Resolved data-$${i} -> $${PEER_IP}"
        break
      fi
      echo "[WAIT] data-$${i} DNS not ready (attempt $${attempt}/30)"
      sleep 5
    done
    if [ -z "$${PEER_IP}" ]; then
      echo "[WARN] Could not resolve data-$${i} — may join cluster later"
    fi
  fi
done

# =============================================================================
# 6. Create directories
# =============================================================================
mkdir -p /opt/data-ha/{redis-data,sentinel-data,rabbitmq-data}

# =============================================================================
# 7. Generate Redis config
# =============================================================================
cat > /opt/data-ha/redis.conf << REDIS_EOF
bind 0.0.0.0
port 6379
requirepass $${REDIS_PASS}
masterauth $${REDIS_PASS}

# Persistence — Hybrid AOF+RDB (best recovery speed + minimal data loss)
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes
save 3600 1 300 100 60 10000

# Split-brain prevention
# Primary rejects writes if < 1 healthy replica within 10s lag
min-replicas-to-write 1
min-replicas-max-lag 10

# Memory
maxmemory ${redis_maxmemory}
maxmemory-policy allkeys-lru

# Logging
loglevel notice
REDIS_EOF

# Nodes 2+ start as replicas of node 1 (Sentinel will manage topology after)
if [ "$${NODE_INDEX}" -ne 1 ]; then
  echo "replicaof data-1.$${DOMAIN} 6379" >> /opt/data-ha/redis.conf
fi

echo "[OK] Redis config generated (node $${NODE_INDEX}$([ $${NODE_INDEX} -eq 1 ] && echo ' — initial primary' || echo ' — replica'))"

# =============================================================================
# 8. Generate Sentinel config
#    - resolve-hostnames: Sentinel uses DNS names instead of IPs
#    - announce-hostname: clients receive DNS names (works with IP changes)
# =============================================================================
cat > /opt/data-ha/sentinel-data/sentinel.conf << SENTINEL_EOF
port 26379
sentinel monitor mymaster data-1.$${DOMAIN} 6379 2
sentinel auth-pass mymaster $${REDIS_PASS}
sentinel down-after-milliseconds mymaster ${sentinel_down_after}
sentinel failover-timeout mymaster 180000
sentinel parallel-syncs mymaster 1
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
SENTINEL_EOF

echo "[OK] Sentinel config generated (quorum=2)"

# =============================================================================
# 9. Generate RabbitMQ config
# =============================================================================
cat > /opt/data-ha/rabbitmq.conf << RABBIT_EOF
# --- Clustering ---
cluster_formation.peer_discovery_backend = classic_config
%{ for i in range(node_count) ~}
cluster_formation.classic_config.nodes.${i + 1} = rabbit@data-${i + 1}
%{ endfor ~}

# Network partition: minority side stops, majority continues
cluster_partition_handling = pause_minority

# --- Resource limits ---
vm_memory_high_watermark.relative = 0.4
vm_memory_high_watermark_paging_ratio = 0.5
disk_free_limit.absolute = 1GB

# --- Queue defaults ---
default_queue_type = quorum

# --- Management ---
management.tcp.port = 15672
RABBIT_EOF

cat > /opt/data-ha/enabled_plugins << 'PLUGINS_EOF'
[rabbitmq_management,rabbitmq_prometheus,rabbitmq_peer_discovery_classic_config].
PLUGINS_EOF

echo "[OK] RabbitMQ config generated"

# =============================================================================
# 10. Generate .env for RabbitMQ container
# =============================================================================
cat > /opt/data-ha/.env << ENV_EOF
RABBITMQ_DEFAULT_USER=$${RABBIT_USER}
RABBITMQ_DEFAULT_PASS=$${RABBIT_PASS}
RABBITMQ_ERLANG_COOKIE=$${ERLANG_COOKIE}
RABBITMQ_NODENAME=rabbit@data-$${NODE_INDEX}
RABBITMQ_USE_LONGNAME=false
ENV_EOF

chmod 600 /opt/data-ha/.env

# =============================================================================
# 11. Generate Docker Compose — network_mode: host
#     Host networking simplifies DNS resolution for clustering:
#     containers share /etc/hosts and resolve peers directly.
# =============================================================================
cat > /opt/data-ha/docker-compose.yml << 'COMPOSE_EOF'
services:
  redis:
    image: redis:7.4.8-alpine
    container_name: redis
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./redis.conf:/usr/local/etc/redis/redis.conf:ro
      - ./redis-data:/data
    command: redis-server /usr/local/etc/redis/redis.conf
    mem_limit: 384m
    cpus: 0.5
    logging:
      options:
        max-size: "10m"
        max-file: "3"

  sentinel:
    image: redis:7.4.8-alpine
    container_name: sentinel
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./sentinel-data:/data
    command: redis-sentinel /data/sentinel.conf
    mem_limit: 64m
    cpus: 0.25
    depends_on:
      - redis
    logging:
      options:
        max-size: "10m"
        max-file: "3"

  rabbitmq:
    image: rabbitmq:3.13.7-management-alpine
    container_name: rabbitmq
    restart: unless-stopped
    network_mode: host
    env_file: .env
    volumes:
      - ./rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf:ro
      - ./enabled_plugins:/etc/rabbitmq/enabled_plugins:ro
      - ./rabbitmq-data:/var/lib/rabbitmq
    mem_limit: 512m
    cpus: 0.5
    logging:
      options:
        max-size: "10m"
        max-file: "3"
COMPOSE_EOF

echo "[OK] Docker Compose generated"

# =============================================================================
# 12. OS tuning for Redis
# =============================================================================
# Prevent fork() failure during BGSAVE/AOF rewrite
sysctl -w vm.overcommit_memory=1
echo 'vm.overcommit_memory = 1' >> /etc/sysctl.conf

# Redis recommends somaxconn >= 512 (default 128 is too low)
sysctl -w net.core.somaxconn=512
echo 'net.core.somaxconn = 512' >> /etc/sysctl.conf

# Disable THP (causes latency spikes)
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

# Persist THP disable across reboots
cat > /etc/systemd/system/disable-thp.service << 'THP_EOF'
[Unit]
Description=Disable Transparent Huge Pages
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=multi-user.target
THP_EOF
systemctl enable disable-thp

echo "[OK] OS tuning applied"

# =============================================================================
# 13. Start services
# =============================================================================
cd /opt/data-ha
docker compose up -d

echo "[OK] Docker services starting..."

# =============================================================================
# 14. Wait for Redis
# =============================================================================
echo "Waiting for Redis..."
for i in $(seq 1 30); do
  if docker exec redis redis-cli -a "$${REDIS_PASS}" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
    echo "[OK] Redis is ready"
    break
  fi
  sleep 2
done

# =============================================================================
# 15. Wait for RabbitMQ + cluster join
# =============================================================================
echo "Waiting for RabbitMQ..."
RABBIT_READY=false
for i in $(seq 1 60); do
  if docker exec rabbitmq rabbitmqctl status &>/dev/null; then
    echo "[OK] RabbitMQ is ready"
    RABBIT_READY=true
    break
  fi
  sleep 5
done

# Cluster join for non-seed nodes
if [ "$${RABBIT_READY}" = true ] && [ "$${NODE_INDEX}" -ne 1 ]; then
  # Check if already clustered
  CLUSTER_SIZE=$(docker exec rabbitmq rabbitmqctl cluster_status --formatter json 2>/dev/null \
    | jq -r '.running_nodes | length' 2>/dev/null || echo "0")

  if [ "$${CLUSTER_SIZE}" -le 1 ]; then
    echo "Joining RabbitMQ cluster..."

    # Try each peer until one succeeds
    JOINED=false
    for peer_idx in $(seq 1 $${NODE_COUNT}); do
      if [ "$${peer_idx}" -ne "$${NODE_INDEX}" ]; then
        PEER="rabbit@data-$${peer_idx}"
        echo "  Trying $${PEER}..."
        if docker exec rabbitmq rabbitmqctl stop_app && \
           docker exec rabbitmq rabbitmqctl force_reset && \
           docker exec rabbitmq rabbitmqctl join_cluster "$${PEER}" && \
           docker exec rabbitmq rabbitmqctl start_app; then
          echo "[OK] Joined cluster via $${PEER}"
          JOINED=true
          break
        else
          echo "  [WARN] Failed to join via $${PEER}, trying next..."
          docker exec rabbitmq rabbitmqctl start_app 2>/dev/null || true
        fi
      fi
    done

    if [ "$${JOINED}" = false ]; then
      echo "[WARN] Could not join any cluster — running standalone (will retry on next peer startup)"
    fi
  else
    echo "[OK] Already in cluster ($${CLUSTER_SIZE} nodes)"
  fi
fi

# =============================================================================
# 16. Final status
# =============================================================================
echo ""
echo "============================================"
echo " Data HA Node $${NODE_INDEX} — READY"
echo "============================================"
echo ""
echo "Redis:"
docker exec redis redis-cli -a "$${REDIS_PASS}" --no-auth-warning info replication 2>/dev/null | grep -E "role|connected_slaves|master_host" || true
echo ""
echo "Sentinel:"
docker exec sentinel redis-cli -p 26379 sentinel masters 2>/dev/null | head -20 || true
echo ""
echo "RabbitMQ:"
docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null | head -20 || true
echo ""
echo "[DONE] Initialization complete at $(date)"