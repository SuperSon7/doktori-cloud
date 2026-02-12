#!/bin/bash
set -euo pipefail

# =============================================================================
# Terraform State Migration Script
# Splits root infra state into per-resource-type directories
# =============================================================================
#
# Usage:
#   ./migrate.sh <step>
#
# Steps (run in order):
#   0  - Backup current state
#   1  - Migrate networking
#   2  - Migrate compute
#   3  - Migrate monitoring
#   4  - Migrate iam
#   5  - Migrate dns
#   6  - Migrate lightsail
#   7  - Verify all modules
#   8  - Remove resources from old infra state
#   9  - Cleanup old root .tf files
#
# IMPORTANT: Run steps 1-6 in order (dependency chain)
# After each step, verify with: cd <module> && terraform plan
# =============================================================================

TERRAFORM_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$TERRAFORM_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Helper: get resource ID from current infra state
get_resource_id() {
  local resource="$1"
  cd "$INFRA_DIR"
  terraform state show "$resource" 2>/dev/null | grep -E '^\s+id\s+=' | head -1 | awk -F'"' '{print $2}'
}

step_0_backup() {
  log_info "=== Step 0: Backing up current infra state ==="
  cd "$INFRA_DIR"
  terraform state pull > /tmp/infra-state-backup-$(date +%Y%m%d-%H%M%S).json
  log_info "Backup saved to /tmp/infra-state-backup-*.json"
}

step_1_networking() {
  log_info "=== Step 1: Migrating networking ==="
  cd "$TERRAFORM_DIR/networking"
  terraform init

  log_info "Getting resource IDs from infra state..."
  local vpc_id=$(get_resource_id "aws_vpc.main")
  local igw_id=$(get_resource_id "aws_internet_gateway.main")
  local subnet_id=$(get_resource_id "aws_subnet.public")
  local rt_id=$(get_resource_id "aws_route_table.public")
  local rta_id="${subnet_id}/${rt_id}"

  log_info "Importing resources..."
  terraform import aws_vpc.main "$vpc_id"
  terraform import aws_internet_gateway.main "$igw_id"
  terraform import aws_subnet.public "$subnet_id"
  terraform import aws_route_table.public "$rt_id"
  terraform import aws_route_table_association.public "$rta_id"

  log_info "Verifying..."
  terraform plan
  log_info "Networking migration complete. Verify 'No changes' above."
}

step_2_compute() {
  log_info "=== Step 2: Migrating compute ==="
  cd "$TERRAFORM_DIR/compute"
  terraform init

  log_info "Getting resource IDs from infra state..."
  local sg_id=$(get_resource_id "aws_security_group.app")
  local instance_id=$(get_resource_id "aws_instance.app")
  local eip_id=$(get_resource_id "aws_eip.app")
  local role_name=$(cd "$INFRA_DIR" && terraform state show aws_iam_role.ec2_role 2>/dev/null | grep -E '^\s+name\s+=' | head -1 | awk -F'"' '{print $2}')
  local profile_name=$(cd "$INFRA_DIR" && terraform state show aws_iam_instance_profile.ec2_profile 2>/dev/null | grep -E '^\s+name\s+=' | head -1 | awk -F'"' '{print $2}')

  log_info "Importing resources..."
  terraform import aws_security_group.app "$sg_id"
  terraform import aws_instance.app "$instance_id"
  terraform import aws_eip.app "$eip_id"
  terraform import aws_eip_association.app "$eip_id"
  terraform import aws_iam_role.ec2_role "$role_name"
  terraform import aws_iam_role_policy.parameter_store_read "${role_name}:doktori-dev-parameter-store-read"
  terraform import aws_iam_role_policy.s3_access "${role_name}:doktori-dev-s3-access"
  terraform import aws_iam_instance_profile.ec2_profile "$profile_name"

  log_info "Verifying..."
  terraform plan
  log_info "Compute migration complete. Verify 'No changes' above."
}

step_3_monitoring() {
  log_info "=== Step 3: Migrating monitoring ==="
  cd "$TERRAFORM_DIR/monitoring"
  terraform init

  log_info "Getting resource IDs from infra state..."
  local sg_id=$(get_resource_id "aws_security_group.monitoring")
  local inst1_id=$(get_resource_id "aws_instance.monitoring")
  local inst2_id=$(get_resource_id "aws_instance.monitoring1")
  local eip1_id=$(get_resource_id "aws_eip.monitoring")
  local eip2_id=$(get_resource_id "aws_eip.monitoring1")

  log_info "Importing resources..."
  terraform import aws_security_group.monitoring "$sg_id"
  terraform import aws_instance.monitoring "$inst1_id"
  terraform import aws_instance.monitoring1 "$inst2_id"
  terraform import aws_eip.monitoring "$eip1_id"
  terraform import aws_eip_association.monitoring "$eip1_id"
  terraform import aws_eip.monitoring1 "$eip2_id"
  terraform import aws_eip_association.monitoring1 "$eip2_id"

  log_info "Verifying..."
  terraform plan
  log_info "Monitoring migration complete. Verify 'No changes' above."
}

step_4_iam() {
  log_info "=== Step 4: Migrating iam ==="
  cd "$TERRAFORM_DIR/iam"
  terraform init

  log_info "Getting resource IDs from infra state..."
  local oidc_arn=$(cd "$INFRA_DIR" && terraform state show aws_iam_openid_connect_provider.github_actions 2>/dev/null | grep -E '^\s+arn\s+=' | head -1 | awk -F'"' '{print $2}')
  local gha_role_name=$(cd "$INFRA_DIR" && terraform state show aws_iam_role.github_actions_deploy 2>/dev/null | grep -E '^\s+name\s+=' | head -1 | awk -F'"' '{print $2}')

  log_info "Importing resources..."
  terraform import aws_iam_openid_connect_provider.github_actions "$oidc_arn"
  terraform import aws_iam_role.github_actions_deploy "$gha_role_name"
  terraform import aws_iam_user.github_action "doktori-github-action"

  # Get policy ARNs
  local dev_policy_arn=$(cd "$INFRA_DIR" && terraform state show aws_iam_policy.dev_github_actions 2>/dev/null | grep -E '^\s+arn\s+=' | head -1 | awk -F'"' '{print $2}')
  local prod_policy_arn=$(cd "$INFRA_DIR" && terraform state show aws_iam_policy.prod_github_actions 2>/dev/null | grep -E '^\s+arn\s+=' | head -1 | awk -F'"' '{print $2}')
  local ps_policy_arn=$(cd "$INFRA_DIR" && terraform state show aws_iam_policy.prod_parameter_store_read 2>/dev/null | grep -E '^\s+arn\s+=' | head -1 | awk -F'"' '{print $2}')

  terraform import aws_iam_policy.dev_github_actions "$dev_policy_arn"
  terraform import aws_iam_policy.prod_github_actions "$prod_policy_arn"
  terraform import "aws_iam_user_policy_attachment.github_action_dev" "doktori-github-action/$dev_policy_arn"
  terraform import "aws_iam_user_policy_attachment.github_action_prod" "doktori-github-action/$prod_policy_arn"

  terraform import aws_iam_user.prod_lightsail "doktori-prod-lightsail"
  terraform import aws_iam_user_policy.prod_lightsail_s3 "doktori-prod-lightsail:doktori-prod-lightsail-s3"
  terraform import aws_iam_policy.prod_parameter_store_read "$ps_policy_arn"
  terraform import "aws_iam_user_policy_attachment.prod_lightsail_parameter_store" "doktori-prod-lightsail/$ps_policy_arn"

  terraform import aws_iam_user.prod_s3_developer "doktori-prod-s3-developer"
  terraform import aws_iam_user_policy.prod_s3_developer "doktori-prod-s3-developer:doktori-prod-s3-developer"

  log_info "Verifying..."
  terraform plan
  log_info "IAM migration complete. Verify 'No changes' above."
}

step_5_dns() {
  log_info "=== Step 5: Migrating dns ==="
  cd "$TERRAFORM_DIR/dns"
  terraform init

  log_info "Getting Route53 zone ID..."
  local zone_id=$(get_resource_id "aws_route53_zone.main")

  log_info "Importing resources..."
  terraform import aws_route53_zone.main "$zone_id"
  terraform import aws_route53_record.root_a "${zone_id}_doktori.kr_A"
  terraform import aws_route53_record.www "${zone_id}_www.doktori.kr_A"
  terraform import aws_route53_record.dev "${zone_id}_dev.doktori.kr_A"
  terraform import aws_route53_record.monitoring "${zone_id}_monitoring.doktori.kr_A"
  terraform import aws_route53_record.mx "${zone_id}_doktori.kr_MX"
  terraform import aws_route53_record.txt "${zone_id}_doktori.kr_TXT"
  terraform import aws_route53_record.dkim "${zone_id}_google._domainkey.doktori.kr_TXT"

  log_info "Verifying..."
  terraform plan
  log_info "DNS migration complete. Verify 'No changes' above."
}

step_6_lightsail() {
  log_info "=== Step 6: Migrating lightsail ==="
  cd "$TERRAFORM_DIR/lightsail"
  terraform init

  log_info "Importing resources..."
  terraform import aws_lightsail_instance.prod "doctory-mvp-bigbang"
  terraform import aws_lightsail_instance.ubuntu1 "Ubuntu-1"

  log_info "Verifying..."
  terraform plan
  log_info "Lightsail migration complete. Verify 'No changes' above."
}

step_7_verify() {
  log_info "=== Step 7: Verifying all modules ==="
  local modules=("networking" "compute" "monitoring" "iam" "dns" "lightsail")
  local failed=0

  for mod in "${modules[@]}"; do
    log_info "Checking $mod..."
    cd "$TERRAFORM_DIR/$mod"
    if terraform plan -detailed-exitcode 2>&1 | tail -5; then
      log_info "$mod: OK"
    else
      log_error "$mod: CHANGES DETECTED"
      failed=1
    fi
  done

  if [ $failed -eq 0 ]; then
    log_info "All modules verified successfully!"
  else
    log_error "Some modules have pending changes. Fix before proceeding."
    exit 1
  fi
}

step_8_remove_from_old_state() {
  log_info "=== Step 8: Removing resources from old infra state ==="
  cd "$INFRA_DIR"

  log_warn "This will remove resources from the OLD infra state."
  log_warn "Make sure all imports in new states are verified first!"
  read -p "Continue? (y/N) " confirm
  [ "$confirm" = "y" ] || exit 0

  # Networking
  terraform state rm aws_vpc.main
  terraform state rm aws_internet_gateway.main
  terraform state rm aws_subnet.public
  terraform state rm aws_route_table.public
  terraform state rm aws_route_table_association.public

  # Compute (SG + EC2 + IAM Role)
  terraform state rm aws_security_group.app
  terraform state rm aws_instance.app
  terraform state rm aws_eip.app
  terraform state rm aws_eip_association.app
  terraform state rm aws_iam_role.ec2_role
  terraform state rm aws_iam_role_policy.parameter_store_read
  terraform state rm aws_iam_role_policy.s3_access
  terraform state rm aws_iam_instance_profile.ec2_profile

  # Monitoring
  terraform state rm aws_security_group.monitoring
  terraform state rm aws_instance.monitoring
  terraform state rm aws_instance.monitoring1
  terraform state rm aws_eip.monitoring
  terraform state rm aws_eip_association.monitoring
  terraform state rm aws_eip.monitoring1
  terraform state rm aws_eip_association.monitoring1

  # IAM
  terraform state rm aws_iam_openid_connect_provider.github_actions
  terraform state rm aws_iam_role.github_actions_deploy
  terraform state rm aws_iam_user.github_action
  terraform state rm aws_iam_policy.dev_github_actions
  terraform state rm aws_iam_policy.prod_github_actions
  terraform state rm aws_iam_user_policy_attachment.github_action_dev
  terraform state rm aws_iam_user_policy_attachment.github_action_prod
  terraform state rm aws_iam_user.prod_lightsail
  terraform state rm aws_iam_user_policy.prod_lightsail_s3
  terraform state rm aws_iam_policy.prod_parameter_store_read
  terraform state rm aws_iam_user_policy_attachment.prod_lightsail_parameter_store
  terraform state rm aws_iam_user.prod_s3_developer
  terraform state rm aws_iam_user_policy.prod_s3_developer

  # DNS
  terraform state rm aws_route53_zone.main
  terraform state rm aws_route53_record.root_a
  terraform state rm aws_route53_record.www
  terraform state rm aws_route53_record.dev
  terraform state rm aws_route53_record.monitoring
  terraform state rm aws_route53_record.mx
  terraform state rm aws_route53_record.txt
  terraform state rm aws_route53_record.dkim

  # Lightsail
  terraform state rm aws_lightsail_instance.prod
  terraform state rm aws_lightsail_instance.ubuntu1

  log_info "All resources removed from old infra state."
}

step_9_cleanup() {
  log_info "=== Step 9: Cleaning up old root .tf files ==="
  cd "$INFRA_DIR"

  log_warn "This will delete the old root .tf files:"
  log_warn "  vpc.tf, ec2.tf, security_groups.tf, monitoring.tf"
  log_warn "  iam.tf, route53.tf, lightsail.tf"
  log_warn "  providers.tf, variables.tf, outputs.tf"
  read -p "Continue? (y/N) " confirm
  [ "$confirm" = "y" ] || exit 0

  rm -f vpc.tf ec2.tf security_groups.tf monitoring.tf
  rm -f iam.tf route53.tf lightsail.tf
  rm -f providers.tf variables.tf outputs.tf

  log_info "Old root .tf files deleted."
  log_info "Migration complete!"
}

# =============================================================================
# Main
# =============================================================================
case "${1:-help}" in
  0) step_0_backup ;;
  1) step_1_networking ;;
  2) step_2_compute ;;
  3) step_3_monitoring ;;
  4) step_4_iam ;;
  5) step_5_dns ;;
  6) step_6_lightsail ;;
  7) step_7_verify ;;
  8) step_8_remove_from_old_state ;;
  9) step_9_cleanup ;;
  *)
    echo "Usage: $0 <step>"
    echo ""
    echo "Steps (run in order):"
    echo "  0  Backup current state"
    echo "  1  Migrate networking"
    echo "  2  Migrate compute"
    echo "  3  Migrate monitoring"
    echo "  4  Migrate iam"
    echo "  5  Migrate dns"
    echo "  6  Migrate lightsail"
    echo "  7  Verify all modules"
    echo "  8  Remove from old infra state"
    echo "  9  Cleanup old root .tf files"
    ;;
esac
