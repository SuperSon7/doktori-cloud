#!/bin/bash
# =============================================================================
# Terraform Module Migration Script — Phase 1 (networking + compute + database)
#
# 기존 state (prod/networking, prod/compute, ...) →
# 새 state (prod/base, prod/app, prod/data) 로 마이그레이션
#
# NOTE: Storage (S3/ECR/KMS) 마이그레이션은 Phase 2에서 별도 진행
#       - S3 버킷: Terraform 미관리 상태 → import 필요
#       - ECR: prod/ecr state → prod/base로 이동 예정
#       - KMS: Terraform 미관리 상태 → import 필요
#
# Usage:
#   ./scripts/migrate.sh backup        # 1단계: state 백업
#   ./scripts/migrate.sh dev-base      # 2단계: dev base 마이그레이션
#   ./scripts/migrate.sh dev-app       # 3단계: dev app 마이그레이션
#   ./scripts/migrate.sh prod-base     # 4단계: prod base 마이그레이션
#   ./scripts/migrate.sh prod-app      # 5단계: prod app 마이그레이션
#   ./scripts/migrate.sh prod-data     # 6단계: prod data 마이그레이션
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"
STATE_BUCKET="doktori-v2-terraform-state"
REGION="ap-northeast-2"
BACKUP_DIR="$TF_DIR/state-backup"
TMP_DIR=$(mktemp -d)

trap 'rm -rf "$TMP_DIR"' EXIT

log() { echo -e "\n\033[1;34m=== $1 ===\033[0m"; }
ok()  { echo -e "\033[1;32m✓ $1\033[0m"; }
err() { echo -e "\033[1;31m✗ $1\033[0m" >&2; exit 1; }

# state mv wrapper — 실패 시 skip (이미 이동되었거나 없는 경우)
state_mv() {
  local state_flag="$1"
  local state_out_flag="$2"
  local old_addr="$3"
  local new_addr="$4"

  echo "  mv: $old_addr → $new_addr"
  terraform state mv \
    -state="$state_flag" \
    -state-out="$state_out_flag" \
    "$old_addr" "$new_addr" > /dev/null 2>&1 || {
    echo "  ⚠ skip (already moved or not found): $old_addr"
  }
}

# =============================================================================
# backup: S3 state 전체 백업
# =============================================================================
do_backup() {
  log "State 백업 시작"
  mkdir -p "$BACKUP_DIR"
  aws s3 cp "s3://$STATE_BUCKET/" "$BACKUP_DIR/" --recursive --region "$REGION"
  ok "백업 완료: $BACKUP_DIR"
  echo "  복원 명령: aws s3 cp $BACKUP_DIR/ s3://$STATE_BUCKET/ --recursive"
}

# =============================================================================
# dev-base: nonprod/networking → nonprod/base (networking only)
# =============================================================================
do_dev_base() {
  log "Dev Base 마이그레이션 (nonprod/networking → nonprod/base)"

  local ENV_DIR="$TF_DIR/environments/dev/base"
  local OLD_NET="$TMP_DIR/nonprod-networking.tfstate"
  local NEW_STATE="$TMP_DIR/nonprod-base.tfstate"

  # 1. 기존 state 다운로드
  log "Old state 다운로드"
  aws s3 cp "s3://$STATE_BUCKET/nonprod/networking/terraform.tfstate" "$OLD_NET" --region "$REGION"

  # 2. 새 환경 초기화 + 빈 state 가져오기
  log "새 환경 초기화"
  cd "$ENV_DIR"
  terraform init -backend-config="$TF_DIR/backend.hcl" -reconfigure
  terraform state pull > "$NEW_STATE"

  # 3. Networking resources → module.networking
  log "Networking 리소스 이동"
  local NET="$OLD_NET"
  local OUT="$NEW_STATE"

  state_mv "$NET" "$OUT" 'aws_vpc.main' 'module.networking.aws_vpc.main'
  state_mv "$NET" "$OUT" 'aws_internet_gateway.main' 'module.networking.aws_internet_gateway.main'
  state_mv "$NET" "$OUT" 'aws_subnet.public' 'module.networking.aws_subnet.this["public"]'
  state_mv "$NET" "$OUT" 'aws_subnet.private_app' 'module.networking.aws_subnet.this["private_app"]'
  state_mv "$NET" "$OUT" 'aws_subnet.private_db' 'module.networking.aws_subnet.this["private_db"]'
  state_mv "$NET" "$OUT" 'aws_security_group.nat' 'module.networking.aws_security_group.nat'
  state_mv "$NET" "$OUT" 'aws_instance.nat' 'module.networking.aws_instance.nat'
  state_mv "$NET" "$OUT" 'aws_eip.nat' 'module.networking.aws_eip.nat'
  state_mv "$NET" "$OUT" 'aws_eip_association.nat' 'module.networking.aws_eip_association.nat'
  state_mv "$NET" "$OUT" 'aws_route_table.public' 'module.networking.aws_route_table.public'
  state_mv "$NET" "$OUT" 'aws_route_table.private' 'module.networking.aws_route_table.private'
  state_mv "$NET" "$OUT" 'aws_route_table_association.public' 'module.networking.aws_route_table_association.this["public"]'
  state_mv "$NET" "$OUT" 'aws_route_table_association.private_app' 'module.networking.aws_route_table_association.this["private_app"]'
  state_mv "$NET" "$OUT" 'aws_route_table_association.private_db' 'module.networking.aws_route_table_association.this["private_db"]'
  state_mv "$NET" "$OUT" 'aws_vpc_endpoint.s3' 'module.networking.aws_vpc_endpoint.s3'

  # 4. Push new state
  log "New state push"
  terraform state push -force "$NEW_STATE"

  # 5. Import NAT route (기존 nonprod에서는 route table에 inline으로 정의됨)
  log "NAT route import"
  local RT_ID=$(terraform state show 'module.networking.aws_route_table.private' 2>/dev/null | grep '  id ' | awk '{print $NF}' | tr -d '"')
  if [ -n "$RT_ID" ]; then
    terraform import 'module.networking.aws_route.private_nat' "${RT_ID}_0.0.0.0/0" 2>/dev/null || echo "  ⚠ route import skipped (may already exist)"
  fi

  # 6. Plan to check (apply는 수동 확인 후)
  log "검증: terraform plan"
  terraform plan -detailed-exitcode && ok "Dev Base: No changes!" || echo "  ⚠ 변경사항이 있습니다. 위 plan 출력을 확인하세요."
}

# =============================================================================
# dev-app: nonprod/compute → nonprod/app
# =============================================================================
do_dev_app() {
  log "Dev App 마이그레이션 (nonprod/compute → nonprod/app)"

  local ENV_DIR="$TF_DIR/environments/dev/app"
  local OLD_COMPUTE="$TMP_DIR/nonprod-compute.tfstate"
  local NEW_STATE="$TMP_DIR/nonprod-app.tfstate"

  # 1. 기존 state 다운로드
  log "Old state 다운로드"
  aws s3 cp "s3://$STATE_BUCKET/nonprod/compute/terraform.tfstate" "$OLD_COMPUTE" --region "$REGION"

  # 2. 새 환경 초기화
  log "새 환경 초기화"
  cd "$ENV_DIR"
  terraform init -backend-config="$TF_DIR/backend.hcl" -reconfigure
  terraform state pull > "$NEW_STATE"

  # 3. Compute resources → module.compute
  log "Compute 리소스 이동"
  local OLD="$OLD_COMPUTE"
  local OUT="$NEW_STATE"

  # IAM (공유 리소스 — 한 벌)
  state_mv "$OLD" "$OUT" 'aws_iam_role.ec2_ssm' 'module.compute.aws_iam_role.ec2_ssm'
  state_mv "$OLD" "$OUT" 'aws_iam_role_policy_attachment.ssm_managed' 'module.compute.aws_iam_role_policy_attachment.ssm_managed'
  state_mv "$OLD" "$OUT" 'aws_iam_role_policy.ec2_s3_access' 'module.compute.aws_iam_role_policy.ec2_s3_access[0]'
  state_mv "$OLD" "$OUT" 'aws_iam_role_policy.ec2_parameter_store' 'module.compute.aws_iam_role_policy.ec2_parameter_store'
  state_mv "$OLD" "$OUT" 'aws_iam_role_policy.ec2_ecr_pull' 'module.compute.aws_iam_role_policy.ec2_ecr_pull'
  state_mv "$OLD" "$OUT" 'aws_iam_instance_profile.ec2_ssm' 'module.compute.aws_iam_instance_profile.ec2_ssm'

  # dev_app: SG + EC2 + EIP
  state_mv "$OLD" "$OUT" 'aws_security_group.dev_app' 'module.compute.aws_security_group.this["dev_app"]'
  state_mv "$OLD" "$OUT" 'aws_instance.dev_app' 'module.compute.aws_instance.this["dev_app"]'
  state_mv "$OLD" "$OUT" 'aws_eip.dev_app' 'module.compute.aws_eip.this["dev_app"]'
  state_mv "$OLD" "$OUT" 'aws_eip_association.dev_app' 'module.compute.aws_eip_association.this["dev_app"]'

  # dev_ai: SG + EC2 (EIP 없음)
  state_mv "$OLD" "$OUT" 'aws_security_group.dev_ai' 'module.compute.aws_security_group.this["dev_ai"]'
  state_mv "$OLD" "$OUT" 'aws_instance.dev_ai' 'module.compute.aws_instance.this["dev_ai"]'

  # 4. Push
  log "New state push"
  terraform state push -force "$NEW_STATE"

  # 5. SG cross-rule (dev_app → dev_ai port 8000) は新規作成
  # apply で aws_security_group_rule.cross が作成される

  # 6. Verify
  log "검증: terraform plan"
  terraform plan -detailed-exitcode && ok "Dev App: No changes!" || echo "  ⚠ 변경사항이 있습니다. 위 plan 출력을 확인하세요."
}

# =============================================================================
# prod-base: prod/networking → prod/base (networking only)
# =============================================================================
do_prod_base() {
  log "Prod Base 마이그레이션 (prod/networking → prod/base)"

  local ENV_DIR="$TF_DIR/environments/prod/base"
  local OLD_NET="$TMP_DIR/prod-networking.tfstate"
  local NEW_STATE="$TMP_DIR/prod-base.tfstate"

  # 1. 기존 state 다운로드
  log "Old state 다운로드"
  aws s3 cp "s3://$STATE_BUCKET/prod/networking/terraform.tfstate" "$OLD_NET" --region "$REGION"

  # 2. 새 환경 초기화
  log "새 환경 초기화"
  cd "$ENV_DIR"
  terraform init -backend-config="$TF_DIR/backend.hcl" -reconfigure
  terraform state pull > "$NEW_STATE"

  # 3. Networking resources
  log "Networking 리소스 이동"
  local NET="$OLD_NET"
  local OUT="$NEW_STATE"

  state_mv "$NET" "$OUT" 'aws_vpc.main' 'module.networking.aws_vpc.main'
  state_mv "$NET" "$OUT" 'aws_internet_gateway.main' 'module.networking.aws_internet_gateway.main'
  state_mv "$NET" "$OUT" 'aws_subnet.public' 'module.networking.aws_subnet.this["public"]'
  state_mv "$NET" "$OUT" 'aws_subnet.private_app' 'module.networking.aws_subnet.this["private_app"]'
  state_mv "$NET" "$OUT" 'aws_subnet.private_db' 'module.networking.aws_subnet.this["private_db"]'
  state_mv "$NET" "$OUT" 'aws_subnet.private_rds' 'module.networking.aws_subnet.this["private_rds"]'
  state_mv "$NET" "$OUT" 'aws_security_group.nat' 'module.networking.aws_security_group.nat'
  state_mv "$NET" "$OUT" 'aws_instance.nat' 'module.networking.aws_instance.nat'
  state_mv "$NET" "$OUT" 'aws_eip.nat' 'module.networking.aws_eip.nat'
  state_mv "$NET" "$OUT" 'aws_eip_association.nat' 'module.networking.aws_eip_association.nat'
  state_mv "$NET" "$OUT" 'aws_route_table.public' 'module.networking.aws_route_table.public'
  state_mv "$NET" "$OUT" 'aws_route_table.private' 'module.networking.aws_route_table.private'
  state_mv "$NET" "$OUT" 'aws_route_table_association.public' 'module.networking.aws_route_table_association.this["public"]'
  state_mv "$NET" "$OUT" 'aws_route_table_association.private_app' 'module.networking.aws_route_table_association.this["private_app"]'
  state_mv "$NET" "$OUT" 'aws_route_table_association.private_db' 'module.networking.aws_route_table_association.this["private_db"]'
  state_mv "$NET" "$OUT" 'aws_route_table_association.private_rds' 'module.networking.aws_route_table_association.this["private_rds"]'
  state_mv "$NET" "$OUT" 'aws_security_group.vpc_endpoints' 'module.networking.aws_security_group.vpc_endpoints[0]'
  state_mv "$NET" "$OUT" 'aws_vpc_endpoint.ssm' 'module.networking.aws_vpc_endpoint.interface["ssm"]'
  state_mv "$NET" "$OUT" 'aws_vpc_endpoint.ssmmessages' 'module.networking.aws_vpc_endpoint.interface["ssmmessages"]'
  state_mv "$NET" "$OUT" 'aws_vpc_endpoint.ec2messages' 'module.networking.aws_vpc_endpoint.interface["ec2messages"]'
  state_mv "$NET" "$OUT" 'aws_vpc_endpoint.ecr_api' 'module.networking.aws_vpc_endpoint.interface["ecr.api"]'
  state_mv "$NET" "$OUT" 'aws_vpc_endpoint.ecr_dkr' 'module.networking.aws_vpc_endpoint.interface["ecr.dkr"]'
  state_mv "$NET" "$OUT" 'aws_vpc_endpoint.logs' 'module.networking.aws_vpc_endpoint.interface["logs"]'
  state_mv "$NET" "$OUT" 'aws_vpc_endpoint.s3' 'module.networking.aws_vpc_endpoint.s3'

  # 4. Push new state
  log "New state push"
  terraform state push -force "$NEW_STATE"

  # 5. Import NAT route (prod에서는 lifecycle { ignore_changes = [route] } 로 관리되던 route)
  log "NAT route import"
  local RT_ID=$(terraform state show 'module.networking.aws_route_table.private' 2>/dev/null | grep '  id ' | awk '{print $NF}' | tr -d '"')
  if [ -n "$RT_ID" ]; then
    terraform import 'module.networking.aws_route.private_nat' "${RT_ID}_0.0.0.0/0" 2>/dev/null || echo "  ⚠ route import skipped"
  fi

  # 6. Verify
  log "검증: terraform plan"
  terraform plan -detailed-exitcode && ok "Prod Base: No changes!" || echo "  ⚠ 변경사항이 있습니다."
}

# =============================================================================
# prod-app: prod/compute → prod/app
# =============================================================================
do_prod_app() {
  log "Prod App 마이그레이션 (prod/compute → prod/app)"

  local ENV_DIR="$TF_DIR/environments/prod/app"
  local OLD_COMPUTE="$TMP_DIR/prod-compute.tfstate"
  local NEW_STATE="$TMP_DIR/prod-app.tfstate"

  # 1. 기존 state 다운로드
  log "Old state 다운로드"
  aws s3 cp "s3://$STATE_BUCKET/prod/compute/terraform.tfstate" "$OLD_COMPUTE" --region "$REGION"

  # 2. 새 환경 초기화
  log "새 환경 초기화"
  cd "$ENV_DIR"
  terraform init -backend-config="$TF_DIR/backend.hcl" -reconfigure
  terraform state pull > "$NEW_STATE"

  # 3. Compute resources → module.compute
  log "Compute 리소스 이동"
  local OLD="$OLD_COMPUTE"
  local OUT="$NEW_STATE"

  # IAM
  state_mv "$OLD" "$OUT" 'aws_iam_role.ec2_ssm' 'module.compute.aws_iam_role.ec2_ssm'
  state_mv "$OLD" "$OUT" 'aws_iam_role_policy_attachment.ssm_managed' 'module.compute.aws_iam_role_policy_attachment.ssm_managed'
  state_mv "$OLD" "$OUT" 'aws_iam_role_policy.ec2_s3_access' 'module.compute.aws_iam_role_policy.ec2_s3_access[0]'
  state_mv "$OLD" "$OUT" 'aws_iam_role_policy.ec2_parameter_store' 'module.compute.aws_iam_role_policy.ec2_parameter_store'
  state_mv "$OLD" "$OUT" 'aws_iam_role_policy.ec2_ecr_pull' 'module.compute.aws_iam_role_policy.ec2_ecr_pull'
  state_mv "$OLD" "$OUT" 'aws_iam_instance_profile.ec2_ssm' 'module.compute.aws_iam_instance_profile.ec2_ssm'

  # Security Groups
  state_mv "$OLD" "$OUT" 'aws_security_group.nginx' 'module.compute.aws_security_group.this["nginx"]'
  state_mv "$OLD" "$OUT" 'aws_security_group.front' 'module.compute.aws_security_group.this["front"]'
  state_mv "$OLD" "$OUT" 'aws_security_group.api' 'module.compute.aws_security_group.this["api"]'
  state_mv "$OLD" "$OUT" 'aws_security_group.chat' 'module.compute.aws_security_group.this["chat"]'
  state_mv "$OLD" "$OUT" 'aws_security_group.ai' 'module.compute.aws_security_group.this["ai"]'
  state_mv "$OLD" "$OUT" 'aws_security_group.rds_monitoring' 'module.compute.aws_security_group.this["rds_monitoring"]'

  # EC2 Instances
  state_mv "$OLD" "$OUT" 'aws_instance.nginx' 'module.compute.aws_instance.this["nginx"]'
  state_mv "$OLD" "$OUT" 'aws_instance.front' 'module.compute.aws_instance.this["front"]'
  state_mv "$OLD" "$OUT" 'aws_instance.api' 'module.compute.aws_instance.this["api"]'
  state_mv "$OLD" "$OUT" 'aws_instance.chat' 'module.compute.aws_instance.this["chat"]'
  state_mv "$OLD" "$OUT" 'aws_instance.ai' 'module.compute.aws_instance.this["ai"]'
  state_mv "$OLD" "$OUT" 'aws_instance.rds_monitoring' 'module.compute.aws_instance.this["rds_monitoring"]'

  # EIP (nginx only — 기존 EIP는 instance= 직접 연결)
  state_mv "$OLD" "$OUT" 'aws_eip.nginx' 'module.compute.aws_eip.this["nginx"]'

  # 4. Push
  log "New state push"
  terraform state push -force "$NEW_STATE"

  # 5. Import EIP association (기존 EIP는 instance= 직접 연결, 새 코드는 별도 association)
  log "EIP association import"
  local EIP_ALLOC=$(terraform state show 'module.compute.aws_eip.this["nginx"]' 2>/dev/null | grep 'allocation_id' | head -1 | awk '{print $NF}' | tr -d '"')
  if [ -n "$EIP_ALLOC" ]; then
    terraform import 'module.compute.aws_eip_association.this["nginx"]' "$EIP_ALLOC" 2>/dev/null || echo "  ⚠ EIP association import skipped"
  fi

  # 6. SG cross-rules는 새 리소스 — plan/apply에서 생성
  # 기존 inline ingress(nginx→front 등)는 SG에 포함됨
  # 새 코드에서는 별도 aws_security_group_rule.cross로 분리
  # apply 시 inline → separate rule 전환 (순단 ~수 초 가능)

  # 7. Verify
  log "검증: terraform plan"
  terraform plan -detailed-exitcode && ok "Prod App: No changes!" || {
    echo ""
    echo "  ⚠ SG rule 변경이 있을 수 있습니다 (inline → separate rule 전환)"
    echo "  plan 출력을 확인 후, 문제없으면:"
    echo "    cd $ENV_DIR && terraform apply"
  }
}

# =============================================================================
# prod-data: prod/database → prod/data
# =============================================================================
do_prod_data() {
  log "Prod Data 마이그레이션 (prod/database → prod/data)"

  local ENV_DIR="$TF_DIR/environments/prod/data"
  local OLD_DB="$TMP_DIR/prod-database.tfstate"
  local NEW_STATE="$TMP_DIR/prod-data.tfstate"

  # 1. 기존 state 다운로드
  log "Old state 다운로드"
  aws s3 cp "s3://$STATE_BUCKET/prod/database/terraform.tfstate" "$OLD_DB" --region "$REGION"

  # 2. 새 환경 초기화
  log "새 환경 초기화"
  cd "$ENV_DIR"
  terraform init -backend-config="$TF_DIR/backend.hcl" -reconfigure
  terraform state pull > "$NEW_STATE"

  # 3. Database resources → module.database
  log "Database 리소스 이동"
  local OLD="$OLD_DB"
  local OUT="$NEW_STATE"

  state_mv "$OLD" "$OUT" 'aws_security_group.rds' 'module.database.aws_security_group.rds'
  state_mv "$OLD" "$OUT" 'random_password.db' 'module.database.random_password.db'
  state_mv "$OLD" "$OUT" 'aws_ssm_parameter.db_password' 'module.database.aws_ssm_parameter.db_password'
  state_mv "$OLD" "$OUT" 'aws_db_subnet_group.main' 'module.database.aws_db_subnet_group.main'
  state_mv "$OLD" "$OUT" 'aws_db_parameter_group.main' 'module.database.aws_db_parameter_group.main'
  state_mv "$OLD" "$OUT" 'aws_db_instance.main' 'module.database.aws_db_instance.main'

  # 4. Push + verify
  log "New state push"
  terraform state push -force "$NEW_STATE"

  log "검증: terraform plan"
  terraform plan -detailed-exitcode && ok "Prod Data: No changes!" || echo "  ⚠ 변경사항이 있습니다."
}

# =============================================================================
# Main
# =============================================================================
case "${1:-}" in
  backup)     do_backup ;;
  dev-base)   do_dev_base ;;
  dev-app)    do_dev_app ;;
  prod-base)  do_prod_base ;;
  prod-app)   do_prod_app ;;
  prod-data)  do_prod_data ;;
  *)
    echo "Usage: $0 {backup|dev-base|dev-app|prod-base|prod-app|prod-data}"
    echo ""
    echo "실행 순서:"
    echo "  1. $0 backup        # state 백업 (필수)"
    echo "  2. $0 dev-base      # dev networking 마이그레이션"
    echo "  3. $0 dev-app       # dev compute 마이그레이션 (dev_app + dev_ai)"
    echo "  4. $0 prod-base     # prod networking 마이그레이션"
    echo "  5. $0 prod-app      # prod compute 마이그레이션 (SG rule 순단 가능)"
    echo "  6. $0 prod-data     # prod database 마이그레이션"
    echo ""
    echo "⚠ 각 단계 후 'terraform plan' 결과를 확인하세요!"
    echo "⚠ 복원: aws s3 cp state-backup/ s3://doktori-v2-terraform-state/ --recursive"
    exit 1
    ;;
esac
