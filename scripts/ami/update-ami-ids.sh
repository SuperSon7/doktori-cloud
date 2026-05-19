#!/usr/bin/env bash
# =============================================================================
# AMI ID 업데이트 스크립트
#
# Packer 빌드 후 생성된 manifest-*.json을 읽어
# terraform/environments/prod/{app,data,base}와 terraform/monitoring/base의
# AMI ID 기본값을 업데이트함.
#
# Usage:
#   ./scripts/ami/update-ami-ids.sh [--dry-run]
#
# 사전 조건:
#   - jq 설치
#   - packer build 완료 후 manifest-*.json 존재
#
# 버전 관리 흐름:
#   1. packer/variables.pkr.hcl 버전 수정
#   2. packer build packer/
#   3. ./scripts/ami/update-ami-ids.sh
#   4. git add + commit + PR
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PACKER_DIR="${PROJECT_ROOT}/packer"
APP_VARS_FILE="${PROJECT_ROOT}/terraform/environments/prod/app/variables.tf"
DATA_VARS_FILE="${PROJECT_ROOT}/terraform/environments/prod/data/variables.tf"
BASE_VARS_FILE="${PROJECT_ROOT}/terraform/environments/prod/base/variables.tf"
MONITORING_BASE_VARS_FILE="${PROJECT_ROOT}/terraform/monitoring/base/variables.tf"
DEV_APP_VARS_FILE="${PROJECT_ROOT}/terraform/environments/dev/app/variables.tf"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--dry-run]"
      echo "  manifest-*.json을 읽어 variables.tf AMI ID 기본값 업데이트"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq가 필요합니다 (brew install jq / apt install jq)"
  exit 1
fi

if [ ! -f "$APP_VARS_FILE" ]; then
  echo "ERROR: variables.tf 없음: $APP_VARS_FILE"
  exit 1
fi

if [ ! -f "$DATA_VARS_FILE" ]; then
  echo "ERROR: variables.tf 없음: $DATA_VARS_FILE"
  exit 1
fi

if [ ! -f "$BASE_VARS_FILE" ]; then
  echo "ERROR: variables.tf 없음: $BASE_VARS_FILE"
  exit 1
fi

if [ ! -f "$MONITORING_BASE_VARS_FILE" ]; then
  echo "ERROR: variables.tf 없음: $MONITORING_BASE_VARS_FILE"
  exit 1
fi

if [ ! -f "$DEV_APP_VARS_FILE" ]; then
  echo "ERROR: variables.tf 없음: $DEV_APP_VARS_FILE"
  exit 1
fi

# manifest 파일 → Terraform 변수명 매핑
# variables.tf의 변수에 # packer:<key> 주석이 있어야 함
declare -A MANIFEST_MAP=(
  ["manifest-frontend.json"]="frontend_ami_id"
  ["manifest-k8s-node.json"]="k8s_ami_id"
  ["manifest-redis.json"]="redis_ami_id"
  ["manifest-rabbitmq.json"]="rabbitmq_ami_id"
  ["manifest-mongodb.json"]="mongodb_ami_id"
  ["manifest-rds-monitoring.json"]="rds_monitoring_ami_id"
  ["manifest-nat.json"]="nat_ami_id"
  ["manifest-dev-app.json"]="dev_app_ami_id"
  ["manifest-dev-ai.json"]="dev_ai_ami_id"
)

declare -A VARS_FILE_MAP=(
  ["frontend_ami_id"]="$APP_VARS_FILE"
  ["k8s_ami_id"]="$APP_VARS_FILE"
  ["rds_monitoring_ami_id"]="$APP_VARS_FILE"
  ["redis_ami_id"]="$DATA_VARS_FILE"
  ["rabbitmq_ami_id"]="$DATA_VARS_FILE"
  ["mongodb_ami_id"]="$DATA_VARS_FILE"
  ["nat_ami_id"]="$BASE_VARS_FILE $MONITORING_BASE_VARS_FILE"
  ["dev_app_ami_id"]="$DEV_APP_VARS_FILE"
  ["dev_ai_ami_id"]="$DEV_APP_VARS_FILE"
)

UPDATED=0

update_default_in_file() {
  local vars_file="$1"
  local var_name="$2"
  local ami_id="$3"
  local current=""

  if ! grep -q "# packer:${var_name}" "$vars_file"; then
    echo "  WARN: ${vars_file}에 '# packer:${var_name}' 마커 없음 - 스킵"
    return
  fi

  current=$(grep -A2 "# packer:${var_name}" "$vars_file" \
    | grep 'default' \
    | grep -oP '"ami-[^"]*"' \
    | tr -d '"' || echo "")

  if [ "$current" = "$ami_id" ]; then
    echo "  OK (변경 없음): ${var_name} @ ${vars_file} = ${ami_id}"
    return
  fi

  if $DRY_RUN; then
    echo "  DRY-RUN: ${var_name} @ ${vars_file}: ${current:-<empty>} -> ${ami_id}"
    return
  fi

  sed -i "/# packer:${var_name}/{
    n
    s|default *= *\"[^\"]*\"|default = \"${ami_id}\"|
  }" "$vars_file"
  echo "  UPDATED: ${var_name} @ ${vars_file}: ${current:-<empty>} -> ${ami_id}"
  UPDATED=$((UPDATED + 1))
}

for manifest_file in "${!MANIFEST_MAP[@]}"; do
  manifest_path="${PACKER_DIR}/${manifest_file}"
  var_name="${MANIFEST_MAP[$manifest_file]}"
  vars_files="${VARS_FILE_MAP[$var_name]}"

  if [ ! -f "$manifest_path" ]; then
    echo "  SKIP: ${manifest_file} 없음"
    continue
  fi

  # Packer manifest 형식: builds[-1].artifact_id = "region:ami-xxx"
  ami_id=$(jq -r '.builds[-1].artifact_id | split(":")[1]' "$manifest_path")

  if [ -z "$ami_id" ] || [ "$ami_id" = "null" ]; then
    echo "  WARN: ${manifest_file}에서 AMI ID 추출 실패"
    continue
  fi

  for vars_file in ${vars_files}; do
    update_default_in_file "$vars_file" "$var_name" "$ami_id"
  done
done

echo ""
if $DRY_RUN; then
  echo "DRY-RUN 완료. --dry-run 없이 실행하면 위 변경이 적용됩니다."
else
  echo "완료: ${UPDATED}개 변수 업데이트됨"
  if [ $UPDATED -gt 0 ]; then
    echo ""
    echo "다음 단계:"
    echo "  git diff ${APP_VARS_FILE} ${DATA_VARS_FILE} ${BASE_VARS_FILE} ${MONITORING_BASE_VARS_FILE} ${DEV_APP_VARS_FILE}"
    echo "  git add ${APP_VARS_FILE} ${DATA_VARS_FILE} ${BASE_VARS_FILE} ${MONITORING_BASE_VARS_FILE} ${DEV_APP_VARS_FILE} && git commit -m 'chore(ami): update AMI IDs from Packer build'"
  fi
fi
