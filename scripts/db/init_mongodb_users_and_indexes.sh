#!/usr/bin/env bash
# =============================================================================
# MongoDB prod initialization
#
# Run on the MongoDB EC2 instance after /doktori/prod Mongo SSM parameters exist.
# It creates/updates the admin user, app user, collections, and indexes.
# =============================================================================
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-doktori}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
MONGO_HOST="${MONGO_HOST:-127.0.0.1}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_DB="${MONGO_DB:-doktoridb}"

log() { echo "[mongo-init] $*"; }

ssm_get() {
  local name="$1"
  aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "/$PROJECT_NAME/$ENVIRONMENT/$name" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text
}

js_quote() {
  printf '%s' "$1" | jq -Rs .
}

enable_authorization() {
  if grep -q '^security:' /etc/mongod.conf 2>/dev/null; then
    if grep -q '^[[:space:]]*authorization:' /etc/mongod.conf 2>/dev/null; then
      sed -i 's/^[[:space:]]*authorization:.*/  authorization: enabled/' /etc/mongod.conf
    else
      sed -i '/^security:/a\  authorization: enabled' /etc/mongod.conf
    fi
  else
    printf '\nsecurity:\n  authorization: enabled\n' >>/etc/mongod.conf
  fi
}

MONGO_ADMIN_USERNAME="$(ssm_get MONGO_ADMIN_USERNAME)"
MONGO_ADMIN_PASSWORD="$(ssm_get MONGO_ADMIN_PASSWORD)"
MONGO_USERNAME="$(ssm_get MONGO_USERNAME)"
MONGO_PASSWORD="$(ssm_get MONGO_PASSWORD)"

INIT_ADMIN_JS="$(mktemp /tmp/mongo-init-admin.XXXXXX.js)"
INIT_APP_JS="$(mktemp /tmp/mongo-init-app.XXXXXX.js)"
trap 'rm -f "$INIT_ADMIN_JS" "$INIT_APP_JS"' EXIT
chmod 0600 "$INIT_ADMIN_JS" "$INIT_APP_JS"

ADMIN_USER_JSON="$(js_quote "$MONGO_ADMIN_USERNAME")"
ADMIN_PASS_JSON="$(js_quote "$MONGO_ADMIN_PASSWORD")"
APP_USER_JSON="$(js_quote "$MONGO_USERNAME")"
APP_PASS_JSON="$(js_quote "$MONGO_PASSWORD")"
MONGO_DB_JSON="$(js_quote "$MONGO_DB")"

ADMIN_AUTH_OK=false
if mongosh --quiet --host "$MONGO_HOST" --port "$MONGO_PORT" \
    --username "$MONGO_ADMIN_USERNAME" \
    --password "$MONGO_ADMIN_PASSWORD" \
    --authenticationDatabase admin \
    --eval 'db.adminCommand({ ping: 1 }).ok' >/dev/null 2>&1; then
  ADMIN_AUTH_OK=true
else
  cat >"$INIT_ADMIN_JS" <<JS
const adminDb = db.getSiblingDB("admin");
const adminUser = $ADMIN_USER_JSON;
const adminPassword = $ADMIN_PASS_JSON;
const adminRoles = [
  { role: "userAdminAnyDatabase", db: "admin" },
  { role: "dbAdminAnyDatabase", db: "admin" },
  { role: "clusterMonitor", db: "admin" }
];

if (adminDb.getUser(adminUser) === null) {
  adminDb.createUser({ user: adminUser, pwd: adminPassword, roles: adminRoles });
} else {
  adminDb.updateUser(adminUser, { pwd: adminPassword, roles: adminRoles });
}
JS

  log "creating/updating admin user through localhost exception"
  mongosh --quiet --host "$MONGO_HOST" --port "$MONGO_PORT" "$INIT_ADMIN_JS"
fi

cat >"$INIT_APP_JS" <<JS
const adminDb = db.getSiblingDB("admin");
const appDbName = $MONGO_DB_JSON;

function upsertAppUser(username, password, dbName) {
  const roles = [{ role: "readWrite", db: dbName }];
  if (adminDb.getUser(username) === null) {
    adminDb.createUser({ user: username, pwd: password, roles });
  } else {
    adminDb.updateUser(username, { pwd: password, roles });
  }
}

function ensureCollection(database, collectionName) {
  if (!database.getCollectionNames().includes(collectionName)) {
    database.createCollection(collectionName);
  }
}

upsertAppUser($APP_USER_JSON, $APP_PASS_JSON, appDbName);

const appDb = db.getSiblingDB(appDbName);
ensureCollection(appDb, "user_behavior_logs");
appDb.user_behavior_logs.createIndex({ userId: 1, sentAt: -1 }, { name: "idx_user_sent_at" });
appDb.user_behavior_logs.createIndex({ sessionId: 1, sentAt: -1 }, { name: "idx_session_sent_at" });
appDb.user_behavior_logs.createIndex({ meetingId: 1, sentAt: -1 }, { name: "idx_meeting_sent_at" });

ensureCollection(appDb, "messages");
appDb.messages.createIndex({ roomId: 1, senderId: 1, clientMessageId: 1 }, { name: "uk_room_sender_client", unique: true });
appDb.messages.createIndex({ roomId: 1 }, { name: "idx_room_id" });
appDb.messages.createIndex({ roundId: 1 }, { name: "idx_round_id" });
JS

log "ensuring app users, collections, and indexes"
if [ "$ADMIN_AUTH_OK" = true ]; then
  mongosh --quiet --host "$MONGO_HOST" --port "$MONGO_PORT" \
    --username "$MONGO_ADMIN_USERNAME" \
    --password "$MONGO_ADMIN_PASSWORD" \
    --authenticationDatabase admin \
    "$INIT_APP_JS"
else
  mongosh --quiet --host "$MONGO_HOST" --port "$MONGO_PORT" "$INIT_APP_JS"
fi

log "enabling MongoDB authorization"
enable_authorization
systemctl restart mongod

for _ in $(seq 1 30); do
  if mongosh --quiet --host "$MONGO_HOST" --port "$MONGO_PORT" \
      --username "$MONGO_ADMIN_USERNAME" \
      --password "$MONGO_ADMIN_PASSWORD" \
      --authenticationDatabase admin \
      --eval 'db.adminCommand({ ping: 1 }).ok' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

log "done"
