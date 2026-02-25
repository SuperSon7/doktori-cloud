#!/bin/bash
# =============================================================================
# Terraform State Migration Script
# Migrates state from workspace-based to directory-based structure
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "========================================"
echo "Terraform State Migration"
echo "========================================"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI not installed${NC}"
    exit 1
fi

# Check Terraform
if ! command -v terraform &> /dev/null; then
    echo -e "${RED}Error: Terraform not installed${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}WARNING: This script will migrate Terraform state files.${NC}"
echo "Make sure you have:"
echo "  1. Backed up your current state files"
echo "  2. No active terraform operations in progress"
echo ""
read -p "Continue? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# =============================================================================
# Migration: dev workspace -> environments/dev/aws
# =============================================================================
echo ""
echo -e "${GREEN}=== Migrating dev/aws state ===${NC}"

# Copy state from old key to new key using S3 CLI
OLD_KEY="env:/dev/infra/terraform.tfstate"
NEW_KEY="dev/aws/terraform.tfstate"
BUCKET="doktori-terraform-state"

echo "Checking if old state exists..."
if aws s3 ls "s3://${BUCKET}/${OLD_KEY}" 2>/dev/null; then
    echo "Copying state: ${OLD_KEY} -> ${NEW_KEY}"
    aws s3 cp "s3://${BUCKET}/${OLD_KEY}" "s3://${BUCKET}/${NEW_KEY}"
    echo -e "${GREEN}Done!${NC}"
else
    echo -e "${YELLOW}Old state not found at ${OLD_KEY}, skipping...${NC}"
fi

# =============================================================================
# Migration: dev workspace s3 -> environments/dev/aws-s3
# =============================================================================
echo ""
echo -e "${GREEN}=== Migrating dev/aws-s3 state ===${NC}"

OLD_KEY="env:/dev/s3/terraform.tfstate"
NEW_KEY="dev/s3/terraform.tfstate"

if aws s3 ls "s3://${BUCKET}/${OLD_KEY}" 2>/dev/null; then
    echo "Copying state: ${OLD_KEY} -> ${NEW_KEY}"
    aws s3 cp "s3://${BUCKET}/${OLD_KEY}" "s3://${BUCKET}/${NEW_KEY}"
    echo -e "${GREEN}Done!${NC}"
else
    echo -e "${YELLOW}Old state not found at ${OLD_KEY}, skipping...${NC}"
fi

# =============================================================================
# Migration: dev workspace parameter-store -> environments/dev/aws-parameter-store
# =============================================================================
echo ""
echo -e "${GREEN}=== Migrating dev/aws-parameter-store state ===${NC}"

OLD_KEY="env:/dev/parameter-store/terraform.tfstate"
NEW_KEY="dev/parameter-store/terraform.tfstate"

if aws s3 ls "s3://${BUCKET}/${OLD_KEY}" 2>/dev/null; then
    echo "Copying state: ${OLD_KEY} -> ${NEW_KEY}"
    aws s3 cp "s3://${BUCKET}/${OLD_KEY}" "s3://${BUCKET}/${NEW_KEY}"
    echo -e "${GREEN}Done!${NC}"
else
    echo -e "${YELLOW}Old state not found at ${OLD_KEY}, skipping...${NC}"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================"
echo -e "${GREEN}Migration Complete!${NC}"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. cd environments/dev/aws"
echo "  2. Copy terraform.tfvars.example to terraform.tfvars"
echo "  3. terraform init"
echo "  4. terraform plan (verify no changes)"
echo ""
echo -e "${YELLOW}After verifying, you can delete the legacy directories:${NC}"
echo "  - terraform/"
echo "  - terraform-gcp/"
echo "  - main.tf"
