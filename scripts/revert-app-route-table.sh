#!/bin/bash
# =============================================================================
# 마이그레이션 완료 후 라우트 테이블 원복 스크립트
#
# 배경: Lightsail → RDS 연결을 위해 private RT에 IGW 라우트가 설정되어 있었고,
#        app 서브넷의 outbound를 위해 임시로 별도 RT(NAT)를 생성하여 분리함.
#
# 이 스크립트 실행 시:
#   1. app 서브넷을 원래 private RT로 복귀
#   2. 원래 private RT의 라우트를 IGW → NAT으로 변경
#   3. 임시 app RT 삭제
#   4. S3 VPC endpoint에서 임시 RT 제거
#
# 실행: bash scripts/revert-app-route-table.sh
# =============================================================================

set -euo pipefail

REGION="ap-northeast-2"

# 리소스 ID
ORIGINAL_PRIVATE_RT="rtb-09c76d5f75d9e9a8e"   # doktori-prod-private-rt (원래)
TEMP_APP_RT="rtb-07d1a844bcd302e93"             # doktori-prod-private-app-rt (임시)
APP_SUBNET="subnet-0a6a3170675ee0f55"           # doktori-prod-private-app
NAT_ENI="eni-09fff90c3e8f44375"                 # doktori-prod-nat ENI
IGW="igw-0e93963b76eb8eac6"                     # prod VPC IGW
S3_ENDPOINT="vpce-0654ebb7f4295ea6d"            # S3 VPC Gateway endpoint

echo "=== 마이그레이션 완료 후 라우트 테이블 원복 ==="
echo ""

# Step 1: app 서브넷을 원래 private RT로 복귀
echo "[1/4] app 서브넷 → 원래 private RT 복귀..."
CURRENT_ASSOC=$(aws ec2 describe-route-tables --region $REGION \
  --route-table-ids $TEMP_APP_RT \
  --query "RouteTables[0].Associations[?SubnetId=='$APP_SUBNET'].RouteTableAssociationId" \
  --output text)

if [ -z "$CURRENT_ASSOC" ] || [ "$CURRENT_ASSOC" = "None" ]; then
  echo "  SKIP: app 서브넷이 이미 임시 RT에 없음"
else
  aws ec2 replace-route-table-association \
    --association-id "$CURRENT_ASSOC" \
    --route-table-id "$ORIGINAL_PRIVATE_RT" \
    --region $REGION > /dev/null
  echo "  DONE: association $CURRENT_ASSOC → $ORIGINAL_PRIVATE_RT"
fi

# Step 2: 원래 private RT에서 IGW → NAT으로 변경
echo "[2/4] 원래 private RT: 0.0.0.0/0 → NAT instance..."
aws ec2 replace-route \
  --route-table-id "$ORIGINAL_PRIVATE_RT" \
  --destination-cidr-block "0.0.0.0/0" \
  --network-interface-id "$NAT_ENI" \
  --region $REGION
echo "  DONE: IGW → NAT"

# Step 3: S3 endpoint에서 임시 RT 제거
echo "[3/4] S3 VPC endpoint에서 임시 RT 제거..."
aws ec2 modify-vpc-endpoint \
  --vpc-endpoint-id "$S3_ENDPOINT" \
  --remove-route-table-ids "$TEMP_APP_RT" \
  --region $REGION > /dev/null
echo "  DONE"

# Step 4: 임시 RT 삭제
echo "[4/4] 임시 RT 삭제..."
aws ec2 delete-route-table \
  --route-table-id "$TEMP_APP_RT" \
  --region $REGION
echo "  DONE: $TEMP_APP_RT deleted"

echo ""
echo "=== 원복 완료 ==="
echo "검증: aws ec2 describe-route-tables --region $REGION --route-table-ids $ORIGINAL_PRIVATE_RT --query 'RouteTables[0].Routes[]' --output table"