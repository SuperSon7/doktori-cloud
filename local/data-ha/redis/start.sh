#!/bin/sh
set -eu
: "${REDIS_PASSWORD:?}"
: "${NODE_NAME:?}"
if [ ! -f /data/redis.conf ]; then
  umask 077
  cat >/data/redis.conf <<EOF
bind 0.0.0.0
protected-mode yes
port 6379
dir /data
appendonly yes
appendfsync everysec
requirepass $REDIS_PASSWORD
masterauth $REDIS_PASSWORD
replica-announce-ip $NODE_NAME
replica-announce-port 6379
min-replicas-to-write 1
min-replicas-max-lag 5
EOF
  if [ "$NODE_NAME" != redis-a ]; then
    echo 'replicaof redis-a 6379' >>/data/redis.conf
  fi
fi
# Preserve the config rewritten by Sentinel across restarts.
chown -R redis:redis /data
exec /usr/local/bin/docker-entrypoint.sh redis-server /data/redis.conf
