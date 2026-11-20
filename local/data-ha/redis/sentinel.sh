#!/bin/sh
set -eu
: "${REDIS_PASSWORD:?}"
: "${NODE_NAME:?}"
if [ ! -f /data/sentinel.conf ]; then
  umask 077
  cat >/data/sentinel.conf <<EOF
bind 0.0.0.0
protected-mode yes
port 26379
dir /data
requirepass $REDIS_PASSWORD
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel announce-ip $NODE_NAME
sentinel announce-port 26379
sentinel monitor doktori-master redis-a 6379 2
sentinel auth-pass doktori-master $REDIS_PASSWORD
sentinel sentinel-pass $REDIS_PASSWORD
sentinel down-after-milliseconds doktori-master 5000
sentinel failover-timeout doktori-master 60000
sentinel parallel-syncs doktori-master 1
EOF
fi
chown -R redis:redis /data
exec /usr/local/bin/docker-entrypoint.sh redis-server /data/sentinel.conf --sentinel
