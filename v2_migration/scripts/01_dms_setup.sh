#!/usr/bin/env bash
# =============================================================================
# 01_dms_setup.sh — AWS DMS 리소스 자동 생성
# Replication Instance, Source/Target Endpoint, Migration Task를 생성한다.
# =============================================================================
set -euo pipefail

# ─── 색상 정의 ───
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ─── 설정 ───
PROJECT_PREFIX="${PROJECT_PREFIX:-doktori}"
REPLICATION_INSTANCE_CLASS="${DMS_INSTANCE_CLASS:-dms.t3.medium}"
REPLICATION_INSTANCE_ID="${PROJECT_PREFIX}-dms-repl"
ALLOCATED_STORAGE="${DMS_STORAGE_GB:-50}"

# Source (MySQL)
MYSQL_HOST="${MYSQL_HOST:?'MYSQL_HOST required'}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:?'MYSQL_USER required'}"
MYSQL_PASS="${MYSQL_PASS:?'MYSQL_PASS required'}"
MYSQL_DB="${MYSQL_DB:-doktoridb}"
SOURCE_ENDPOINT_ID="${PROJECT_PREFIX}-mysql-source"

# Target (MongoDB)
MONGO_HOST="${MONGO_HOST:?'MONGO_HOST required'}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_USER="${MONGO_USER:-}"
MONGO_PASS="${MONGO_PASS:-}"
MONGO_DB="${MONGO_DB:-doktori_chat}"
MONGO_AUTH_DB="${MONGO_AUTH_DB:-admin}"
TARGET_ENDPOINT_ID="${PROJECT_PREFIX}-mongo-target"

# Networking
SUBNET_GROUP_ID="${DMS_SUBNET_GROUP:-}"
VPC_SECURITY_GROUP="${DMS_SECURITY_GROUP:-}"

# Task
TASK_ID="${PROJECT_PREFIX}-chat-migration"

# =============================================================================
echo "=========================================="
echo " AWS DMS 리소스 자동 생성"
echo "=========================================="
echo ""

# ─── 1. Replication Instance 생성 ───
info "1. Replication Instance 생성: ${REPLICATION_INSTANCE_ID}"

RI_EXISTS=$(aws dms describe-replication-instances \
    --filters "Name=replication-instance-id,Values=${REPLICATION_INSTANCE_ID}" \
    --query "ReplicationInstances[0].ReplicationInstanceIdentifier" \
    --output text 2>/dev/null || echo "None")

if [ "$RI_EXISTS" != "None" ] && [ "$RI_EXISTS" != "" ]; then
    warn "Replication Instance '${REPLICATION_INSTANCE_ID}' 이미 존재 — 건너뜀"
else
    RI_CMD="aws dms create-replication-instance \
        --replication-instance-identifier ${REPLICATION_INSTANCE_ID} \
        --replication-instance-class ${REPLICATION_INSTANCE_CLASS} \
        --allocated-storage ${ALLOCATED_STORAGE} \
        --multi-az \
        --no-publicly-accessible"

    if [ -n "$SUBNET_GROUP_ID" ]; then
        RI_CMD="${RI_CMD} --replication-subnet-group-identifier ${SUBNET_GROUP_ID}"
    fi

    if [ -n "$VPC_SECURITY_GROUP" ]; then
        RI_CMD="${RI_CMD} --vpc-security-group-ids ${VPC_SECURITY_GROUP}"
    fi

    eval "$RI_CMD"
    info "Replication Instance 생성 요청 완료. 프로비저닝 대기 중..."

    aws dms wait replication-instance-available \
        --filters "Name=replication-instance-id,Values=${REPLICATION_INSTANCE_ID}"
    info "Replication Instance 준비 완료"
fi

REPLICATION_INSTANCE_ARN=$(aws dms describe-replication-instances \
    --filters "Name=replication-instance-id,Values=${REPLICATION_INSTANCE_ID}" \
    --query "ReplicationInstances[0].ReplicationInstanceArn" \
    --output text)

info "Replication Instance ARN: ${REPLICATION_INSTANCE_ARN}"
echo ""

# ─── 2. Source Endpoint (MySQL) 생성 ───
info "2. Source Endpoint 생성: ${SOURCE_ENDPOINT_ID}"

SE_EXISTS=$(aws dms describe-endpoints \
    --filters "Name=endpoint-id,Values=${SOURCE_ENDPOINT_ID}" \
    --query "Endpoints[0].EndpointIdentifier" \
    --output text 2>/dev/null || echo "None")

if [ "$SE_EXISTS" != "None" ] && [ "$SE_EXISTS" != "" ]; then
    warn "Source Endpoint '${SOURCE_ENDPOINT_ID}' 이미 존재 — 건너뜀"
else
    aws dms create-endpoint \
        --endpoint-identifier "${SOURCE_ENDPOINT_ID}" \
        --endpoint-type source \
        --engine-name mysql \
        --server-name "${MYSQL_HOST}" \
        --port "${MYSQL_PORT}" \
        --username "${MYSQL_USER}" \
        --password "${MYSQL_PASS}" \
        --database-name "${MYSQL_DB}"
    info "Source Endpoint 생성 완료"
fi

SOURCE_ENDPOINT_ARN=$(aws dms describe-endpoints \
    --filters "Name=endpoint-id,Values=${SOURCE_ENDPOINT_ID}" \
    --query "Endpoints[0].EndpointArn" \
    --output text)

info "Source Endpoint ARN: ${SOURCE_ENDPOINT_ARN}"
echo ""

# ─── 3. Target Endpoint (MongoDB) 생성 ───
info "3. Target Endpoint 생성: ${TARGET_ENDPOINT_ID}"

TE_EXISTS=$(aws dms describe-endpoints \
    --filters "Name=endpoint-id,Values=${TARGET_ENDPOINT_ID}" \
    --query "Endpoints[0].EndpointIdentifier" \
    --output text 2>/dev/null || echo "None")

if [ "$TE_EXISTS" != "None" ] && [ "$TE_EXISTS" != "" ]; then
    warn "Target Endpoint '${TARGET_ENDPOINT_ID}' 이미 존재 — 건너뜀"
else
    MONGO_SETTINGS="{\"AuthType\":\"no\",\"AuthMechanism\":\"default\",\"DatabaseName\":\"${MONGO_DB}\"}"

    if [ -n "$MONGO_USER" ] && [ -n "$MONGO_PASS" ]; then
        MONGO_SETTINGS="{\"AuthType\":\"password\",\"AuthMechanism\":\"scram-sha-256\",\"Username\":\"${MONGO_USER}\",\"Password\":\"${MONGO_PASS}\",\"AuthSource\":\"${MONGO_AUTH_DB}\",\"DatabaseName\":\"${MONGO_DB}\"}"
    fi

    aws dms create-endpoint \
        --endpoint-identifier "${TARGET_ENDPOINT_ID}" \
        --endpoint-type target \
        --engine-name mongodb \
        --server-name "${MONGO_HOST}" \
        --port "${MONGO_PORT}" \
        --database-name "${MONGO_DB}" \
        --mongo-db-settings "${MONGO_SETTINGS}"
    info "Target Endpoint 생성 완료"
fi

TARGET_ENDPOINT_ARN=$(aws dms describe-endpoints \
    --filters "Name=endpoint-id,Values=${TARGET_ENDPOINT_ID}" \
    --query "Endpoints[0].EndpointArn" \
    --output text)

info "Target Endpoint ARN: ${TARGET_ENDPOINT_ARN}"
echo ""

# ─── 4. Endpoint 연결 테스트 ───
info "4. Endpoint 연결 테스트"

test_endpoint() {
    local ep_arn="$1"
    local label="$2"
    aws dms test-connection \
        --replication-instance-arn "${REPLICATION_INSTANCE_ARN}" \
        --endpoint-arn "${ep_arn}" > /dev/null 2>&1

    for i in $(seq 1 30); do
        STATUS=$(aws dms describe-connections \
            --filters "Name=endpoint-arn,Values=${ep_arn}" \
            --query "Connections[0].Status" \
            --output text 2>/dev/null || echo "unknown")
        if [ "$STATUS" = "successful" ]; then
            info "${label} 연결 테스트 성공"
            return 0
        elif [ "$STATUS" = "failed" ]; then
            error "${label} 연결 테스트 실패"
            return 1
        fi
        sleep 10
    done
    error "${label} 연결 테스트 타임아웃"
    return 1
}

test_endpoint "$SOURCE_ENDPOINT_ARN" "Source (MySQL)"
test_endpoint "$TARGET_ENDPOINT_ARN" "Target (MongoDB)"
echo ""

# ─── 5. Table Mapping 생성 ───
info "5. Table Mapping JSON 생성"

TABLE_MAPPING=$(cat <<'MAPPING_EOF'
{
  "rules": [
    {
      "rule-type": "selection",
      "rule-id": "1",
      "rule-name": "select-chatting-rooms",
      "object-locator": { "schema-name": "%", "table-name": "chatting_rooms" },
      "rule-action": "include"
    },
    {
      "rule-type": "selection",
      "rule-id": "2",
      "rule-name": "select-room-rounds",
      "object-locator": { "schema-name": "%", "table-name": "room_rounds" },
      "rule-action": "include"
    },
    {
      "rule-type": "selection",
      "rule-id": "3",
      "rule-name": "select-chatting-room-members",
      "object-locator": { "schema-name": "%", "table-name": "chatting_room_members" },
      "rule-action": "include"
    },
    {
      "rule-type": "selection",
      "rule-id": "4",
      "rule-name": "select-messages",
      "object-locator": { "schema-name": "%", "table-name": "messages" },
      "rule-action": "include"
    },
    {
      "rule-type": "selection",
      "rule-id": "5",
      "rule-name": "select-quizzes",
      "object-locator": { "schema-name": "%", "table-name": "quizzes" },
      "rule-action": "include"
    },
    {
      "rule-type": "selection",
      "rule-id": "6",
      "rule-name": "select-quiz-choices",
      "object-locator": { "schema-name": "%", "table-name": "quiz_choices" },
      "rule-action": "include"
    }
  ]
}
MAPPING_EOF
)

info "Table Mapping 준비 완료 (채팅 도메인 6개 테이블)"
echo ""

# ─── 6. Task 설정 ───
TASK_SETTINGS=$(cat <<'SETTINGS_EOF'
{
  "TargetMetadata": {
    "TargetSchema": "",
    "SupportLobs": true,
    "LimitedSizeLobMode": true,
    "LobMaxSize": 32
  },
  "FullLoadSettings": {
    "TargetTablePrepMode": "DROP_AND_CREATE",
    "MaxFullLoadSubTasks": 4,
    "TransactionConsistencyTimeout": 600,
    "CommitRate": 10000
  },
  "Logging": {
    "EnableLogging": true,
    "LogComponents": [
      { "Id": "TRANSFORMATION", "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "SOURCE_UNLOAD", "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "TARGET_LOAD", "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "SOURCE_CAPTURE", "Severity": "LOGGER_SEVERITY_DEFAULT" },
      { "Id": "TARGET_APPLY", "Severity": "LOGGER_SEVERITY_DEFAULT" }
    ]
  },
  "ControlTablesSettings": {
    "historyTimeslotInMinutes": 5,
    "StatusTableEnabled": true,
    "SuspendedTablesTableEnabled": true,
    "HistoryTableEnabled": true
  },
  "ValidationSettings": {
    "EnableValidation": true,
    "ThreadCount": 5,
    "FailureMaxCount": 100
  },
  "ChangeProcessingTuning": {
    "BatchApplyEnabled": true,
    "BatchApplyPreserveTransaction": true,
    "MemoryLimitTotal": 1024,
    "MemoryKeepTime": 60,
    "StatementCacheSize": 50
  }
}
SETTINGS_EOF
)

# ─── 7. Migration Task 생성 ───
info "7. Migration Task 생성: ${TASK_ID}"

TASK_EXISTS=$(aws dms describe-replication-tasks \
    --filters "Name=replication-task-id,Values=${TASK_ID}" \
    --query "ReplicationTasks[0].ReplicationTaskIdentifier" \
    --output text 2>/dev/null || echo "None")

if [ "$TASK_EXISTS" != "None" ] && [ "$TASK_EXISTS" != "" ]; then
    warn "Migration Task '${TASK_ID}' 이미 존재 — 건너뜀"
else
    aws dms create-replication-task \
        --replication-task-identifier "${TASK_ID}" \
        --source-endpoint-arn "${SOURCE_ENDPOINT_ARN}" \
        --target-endpoint-arn "${TARGET_ENDPOINT_ARN}" \
        --replication-instance-arn "${REPLICATION_INSTANCE_ARN}" \
        --migration-type "full-load-and-cdc" \
        --table-mappings "${TABLE_MAPPING}" \
        --replication-task-settings "${TASK_SETTINGS}"

    info "Migration Task 생성 요청 완료. 준비 대기 중..."

    aws dms wait replication-task-ready \
        --filters "Name=replication-task-id,Values=${TASK_ID}"
    info "Migration Task 준비 완료"
fi

TASK_ARN=$(aws dms describe-replication-tasks \
    --filters "Name=replication-task-id,Values=${TASK_ID}" \
    --query "ReplicationTasks[0].ReplicationTaskArn" \
    --output text)

info "Task ARN: ${TASK_ARN}"
echo ""

# ─── 8. 리소스 요약 ───
echo "=========================================="
echo " DMS 리소스 생성 완료"
echo "=========================================="
echo ""
echo "  Replication Instance : ${REPLICATION_INSTANCE_ID}"
echo "  Source Endpoint       : ${SOURCE_ENDPOINT_ID} (MySQL)"
echo "  Target Endpoint       : ${TARGET_ENDPOINT_ID} (MongoDB)"
echo "  Migration Task        : ${TASK_ID} (full-load-and-cdc)"
echo ""
echo "  다음 단계: Task 시작"
echo "    aws dms start-replication-task \\"
echo "      --replication-task-arn ${TASK_ARN} \\"
echo "      --start-replication-task-type start-replication"
echo ""
