#!/bin/bash
set -euo pipefail

# =============================================================================
# AMI Baking Script — doktori prod base (arm64)
#
# Creates a pre-baked AMI with Docker CE, AWS CLI v2, SSM Agent
# from Ubuntu 22.04 arm64 + user_data.sh
#
# Usage:
#   ./bake-prod-base.sh [--subnet-id SUBNET] [--sg-id SG] [--profile PROFILE_NAME] [--dry-run]
#
# Prerequisites:
#   - AWS CLI v2 configured with sufficient permissions
#   - jq installed
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
USER_DATA_PATH="$PROJECT_ROOT/terraform/prod/compute/scripts/user_data.sh"

# Defaults
REGION="ap-northeast-2"
PROJECT_NAME="doktori"
ENVIRONMENT="prod"
INSTANCE_TYPE="t4g.micro"
DATE_TAG=$(date +%Y%m%d)
AMI_NAME="${PROJECT_NAME}-prod-base-arm64-${DATE_TAG}"
DRY_RUN=false
SUBNET_ID=""
SG_ID=""
INSTANCE_PROFILE=""
AWS_PROFILE_ARG=""

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subnet-id)  SUBNET_ID="$2"; shift 2 ;;
    --sg-id)      SG_ID="$2"; shift 2 ;;
    --profile)    AWS_PROFILE_ARG="--profile $2"; shift 2 ;;
    --instance-profile) INSTANCE_PROFILE="$2"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--subnet-id SUBNET] [--sg-id SG] [--profile AWS_PROFILE] [--instance-profile IAM_PROFILE] [--dry-run]"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

aws_cmd() {
  # shellcheck disable=SC2086
  aws $AWS_PROFILE_ARG --region "$REGION" --output json "$@"
}

# -----------------------------------------------------------------------------
# Resolve source AMI (Ubuntu 22.04 arm64 latest)
# -----------------------------------------------------------------------------
echo "=== Resolving latest Ubuntu 22.04 arm64 AMI ==="
SOURCE_AMI=$(aws_cmd ec2 describe-images \
  --owners 099720109477 \
  --filters \
    "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*" \
    "Name=architecture,Values=arm64" \
    "Name=virtualization-type,Values=hvm" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text)

if [[ -z "$SOURCE_AMI" || "$SOURCE_AMI" == "None" ]]; then
  echo "ERROR: Could not find Ubuntu 22.04 arm64 AMI"
  exit 1
fi
echo "Source AMI: $SOURCE_AMI"

# -----------------------------------------------------------------------------
# Auto-discover subnet if not provided (first public subnet with internet)
# -----------------------------------------------------------------------------
if [[ -z "$SUBNET_ID" ]]; then
  echo "=== Auto-discovering public subnet ==="
  SUBNET_ID=$(aws_cmd ec2 describe-subnets \
    --filters "Name=tag:Name,Values=*${PROJECT_NAME}*pub*" \
    --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)

  if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
    # Fallback: any subnet tagged with project name
    SUBNET_ID=$(aws_cmd ec2 describe-subnets \
      --filters "Name=tag:Name,Values=*${PROJECT_NAME}*" \
      --query 'Subnets[0].SubnetId' --output text)
  fi
fi
echo "Subnet: $SUBNET_ID"

# -----------------------------------------------------------------------------
# Auto-discover security group if not provided
# -----------------------------------------------------------------------------
if [[ -z "$SG_ID" ]]; then
  echo "=== Auto-discovering security group ==="
  VPC_ID=$(aws_cmd ec2 describe-subnets \
    --subnet-ids "$SUBNET_ID" \
    --query 'Subnets[0].VpcId' --output text)

  # Use default SG of the VPC (only need outbound for package install)
  SG_ID=$(aws_cmd ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" \
    --query 'SecurityGroups[0].GroupId' --output text)
fi
echo "Security Group: $SG_ID"

# -----------------------------------------------------------------------------
# Auto-discover instance profile if not provided
# -----------------------------------------------------------------------------
if [[ -z "$INSTANCE_PROFILE" ]]; then
  echo "=== Auto-discovering instance profile ==="
  INSTANCE_PROFILE=$(aws_cmd iam list-instance-profiles \
    --query "InstanceProfiles[?contains(InstanceProfileName, '${PROJECT_NAME}') && contains(InstanceProfileName, '${ENVIRONMENT}')].InstanceProfileName | [0]" \
    --output text 2>/dev/null || true)
fi

if [[ -n "$INSTANCE_PROFILE" && "$INSTANCE_PROFILE" != "None" ]]; then
  echo "Instance Profile: $INSTANCE_PROFILE"
  IAM_ARG="--iam-instance-profile Name=$INSTANCE_PROFILE"
else
  echo "WARNING: No instance profile found. Instance will have no IAM role."
  IAM_ARG=""
fi

# -----------------------------------------------------------------------------
# Prepare user-data (render template variables)
# -----------------------------------------------------------------------------
echo "=== Preparing user data ==="
if [[ ! -f "$USER_DATA_PATH" ]]; then
  echo "ERROR: user_data.sh not found at $USER_DATA_PATH"
  exit 1
fi

# Replace Terraform template variables with actual values
USER_DATA_RENDERED=$(sed \
  -e "s/\${project_name}/$PROJECT_NAME/g" \
  -e "s/\${environment}/$ENVIRONMENT/g" \
  "$USER_DATA_PATH")

# Check for duplicate AMI name
echo "=== Checking for existing AMI with name: $AMI_NAME ==="
EXISTING_AMI=$(aws_cmd ec2 describe-images \
  --owners self \
  --filters "Name=name,Values=$AMI_NAME" \
  --query 'Images[0].ImageId' --output text 2>/dev/null || echo "None")

if [[ "$EXISTING_AMI" != "None" && -n "$EXISTING_AMI" ]]; then
  echo "WARNING: AMI '$AMI_NAME' already exists ($EXISTING_AMI)"
  AMI_NAME="${AMI_NAME}-$(date +%H%M%S)"
  echo "Using name: $AMI_NAME"
fi

if $DRY_RUN; then
  echo ""
  echo "=== DRY RUN — would launch: ==="
  echo "  AMI:              $SOURCE_AMI"
  echo "  Instance Type:    $INSTANCE_TYPE"
  echo "  Subnet:           $SUBNET_ID"
  echo "  Security Group:   $SG_ID"
  echo "  Instance Profile: ${INSTANCE_PROFILE:-none}"
  echo "  Output AMI Name:  $AMI_NAME"
  exit 0
fi

# -----------------------------------------------------------------------------
# Launch temporary instance
# -----------------------------------------------------------------------------
echo "=== Launching temporary instance ==="
RUN_ARGS=(
  ec2 run-instances
  --image-id "$SOURCE_AMI"
  --instance-type "$INSTANCE_TYPE"
  --subnet-id "$SUBNET_ID"
  --security-group-ids "$SG_ID"
  --associate-public-ip-address
  --user-data "$USER_DATA_RENDERED"
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${AMI_NAME}-builder},{Key=Purpose,Value=ami-bake}]"
  --query 'Instances[0].InstanceId'
  --output text
)

if [[ -n "$IAM_ARG" ]]; then
  # shellcheck disable=SC2206
  RUN_ARGS+=($IAM_ARG)
fi

INSTANCE_ID=$(aws_cmd "${RUN_ARGS[@]}")
echo "Instance ID: $INSTANCE_ID"

# Cleanup trap — terminate instance on any failure
cleanup() {
  echo ""
  echo "=== Cleaning up: terminating $INSTANCE_ID ==="
  aws_cmd ec2 terminate-instances --instance-ids "$INSTANCE_ID" > /dev/null 2>&1 || true
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Wait for instance to be running
# -----------------------------------------------------------------------------
echo "=== Waiting for instance to be running ==="
aws_cmd ec2 wait instance-running --instance-ids "$INSTANCE_ID"
echo "Instance is running."

# -----------------------------------------------------------------------------
# Wait for cloud-init to complete (poll via SSM or status checks)
# -----------------------------------------------------------------------------
echo "=== Waiting for cloud-init to complete (checking instance status) ==="
echo "This typically takes 3-5 minutes..."

MAX_WAIT=600  # 10 minutes
ELAPSED=0
INTERVAL=30

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  # Check instance status (2/2 checks passed means OS is up)
  STATUS=$(aws_cmd ec2 describe-instance-status \
    --instance-ids "$INSTANCE_ID" \
    --query 'InstanceStatuses[0].InstanceStatus.Status' \
    --output text 2>/dev/null || echo "initializing")

  SYSTEM_STATUS=$(aws_cmd ec2 describe-instance-status \
    --instance-ids "$INSTANCE_ID" \
    --query 'InstanceStatuses[0].SystemStatus.Status' \
    --output text 2>/dev/null || echo "initializing")

  echo "  [${ELAPSED}s] Instance: $STATUS, System: $SYSTEM_STATUS"

  if [[ "$STATUS" == "ok" && "$SYSTEM_STATUS" == "ok" ]]; then
    echo "Instance status checks passed."
    break
  fi

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  echo "WARNING: Timed out waiting for status checks. Proceeding anyway..."
fi

# Extra wait for cloud-init to finish after status checks pass
echo "=== Waiting additional 120s for cloud-init to finish ==="
sleep 120

# -----------------------------------------------------------------------------
# Stop instance before creating AMI (cleaner snapshot)
# -----------------------------------------------------------------------------
echo "=== Stopping instance for clean snapshot ==="
aws_cmd ec2 stop-instances --instance-ids "$INSTANCE_ID" > /dev/null
aws_cmd ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
echo "Instance stopped."

# -----------------------------------------------------------------------------
# Create AMI
# -----------------------------------------------------------------------------
echo "=== Creating AMI: $AMI_NAME ==="
AMI_ID=$(aws_cmd ec2 create-image \
  --instance-id "$INSTANCE_ID" \
  --name "$AMI_NAME" \
  --description "Doktori prod base ARM64 - Docker CE, AWS CLI v2, SSM Agent" \
  --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=$AMI_NAME},{Key=Project,Value=$PROJECT_NAME},{Key=Environment,Value=$ENVIRONMENT},{Key=Architecture,Value=arm64}]" \
  --query 'ImageId' --output text)

echo "AMI ID: $AMI_ID"

# -----------------------------------------------------------------------------
# Wait for AMI to become available
# -----------------------------------------------------------------------------
echo "=== Waiting for AMI to become available ==="
echo "This may take several minutes..."
aws_cmd ec2 wait image-available --image-ids "$AMI_ID"
echo "AMI is available!"

# Trap will terminate the instance on exit

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "==========================================="
echo "   AMI Baking Complete"
echo "==========================================="
echo "  AMI ID:   $AMI_ID"
echo "  AMI Name: $AMI_NAME"
echo "  Region:   $REGION"
echo "  Arch:     arm64"
echo ""
echo "Use in Terraform:"
echo "  terraform apply -var=\"custom_ami_id=$AMI_ID\""
echo "==========================================="
