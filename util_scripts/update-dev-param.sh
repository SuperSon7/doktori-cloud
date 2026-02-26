#!/bin/bash
set -e

if [ $# -ne 2 ]; then
  echo "사용법: $0 <파라미터명> <새값>"
  echo "예시: $0 KAKAO_BOOK_BASE_URL http://wiremock:8080"
  exit 1
fi

PARAM_NAME="/doktori/dev/$1"
NEW_VALUE="$2"
REGION="ap-northeast-2"

echo "== 변경 전 =="
aws ssm get-parameter --name "$PARAM_NAME" --with-decryption --region "$REGION" \
  --query "Parameter.{Value:Value,LastModified:LastModifiedDate}" --output table 2>/dev/null \
  || echo "(파라미터 없음 - 신규 생성)"

echo ""
echo ">> $PARAM_NAME = $NEW_VALUE 으로 변경 중..."
aws ssm put-parameter \
  --name "$PARAM_NAME" \
  --value "$NEW_VALUE" \
  --type String \
  --overwrite \
  --region "$REGION"

echo ""
echo "== 변경 후 =="
aws ssm get-parameter --name "$PARAM_NAME" --region "$REGION" \
  --query "Parameter.{Value:Value,LastModified:LastModifiedDate}" --output table