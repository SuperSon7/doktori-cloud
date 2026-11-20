#!/bin/bash
set -euo pipefail
install -d -m 0700 -o mongodb -g mongodb /data/configdb
printf '%s' "$MONGO_REPLICA_KEY" >/data/configdb/keyfile
chown mongodb:mongodb /data/configdb/keyfile
chmod 0400 /data/configdb/keyfile
# The official image handles root -> mongodb. Bootstrap users via localhost
# inside mongo-a before adding peers; never start an unauthenticated network node.
exec /usr/local/bin/docker-entrypoint.sh mongod --bind_ip_all --port 27017 \
  --replSet doktori-rs --keyFile /data/configdb/keyfile \
  --wiredTigerCacheSizeGB 0.25
