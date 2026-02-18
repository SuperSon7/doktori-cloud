#!/bin/bash
# =============================================================================
# Parameter Store Secrets 생성/업데이트 스크립트
#
# 사용법:
#   ./create-secrets.sh <environment>
#   예: ./create-secrets.sh dev
#       ./create-secrets.sh prod
#
# 주의: 이 스크립트는 실행 전에 시크릿 값을 직접 입력해야 합니다.
#       절대 git에 커밋하지 마세요!
# =============================================================================

set -e

ENV=${1:-dev}
PROJECT="doktori"
REGION="ap-northeast-2"
KMS_ALIAS="alias/${PROJECT}-${ENV}-parameter-store"

echo "=========================================="
echo "Environment: ${ENV}"
echo "Project: ${PROJECT}"
echo "Region: ${REGION}"
echo "KMS Alias: ${KMS_ALIAS}"
echo "=========================================="

# KMS Key ID 조회
KMS_KEY_ID=$(aws kms describe-key --key-id "${KMS_ALIAS}" --query 'KeyMetadata.KeyId' --output text --region ${REGION})
echo "KMS Key ID: ${KMS_KEY_ID}"
echo ""

# SecureString 생성 함수
create_secret() {
    local name=$1
    local value=$2
    local description=$3

    echo "Creating (SecureString): /${PROJECT}/${ENV}/${name}"
    aws ssm put-parameter \
        --name "/${PROJECT}/${ENV}/${name}" \
        --value "${value}" \
        --type "SecureString" \
        --key-id "${KMS_KEY_ID}" \
        --description "${description}" \
        --overwrite \
        --region ${REGION} \
        --tags "Key=Name,Value=${PROJECT}-${ENV}-${name}" "Key=Environment,Value=${ENV}" "Key=ManagedBy,Value=Script"
}

# String 생성 함수 (암호화 불필요한 설정값)
create_param() {
    local name=$1
    local value=$2
    local description=$3

    echo "Creating (String):       /${PROJECT}/${ENV}/${name}"
    aws ssm put-parameter \
        --name "/${PROJECT}/${ENV}/${name}" \
        --value "${value}" \
        --type "String" \
        --description "${description}" \
        --overwrite \
        --region ${REGION} \
        --tags "Key=Name,Value=${PROJECT}-${ENV}-${name}" "Key=Environment,Value=${ENV}" "Key=ManagedBy,Value=Script"
}

# =============================================================================
# 아래 값들을 실제 시크릿으로 교체하세요
# =============================================================================

# --- Spring Configuration ---
create_secret "SPRING_PROFILES_ACTIVE" "YOUR_VALUE_HERE" "Spring active profile"

# --- Database Configuration ---
create_secret "DB_URL" "YOUR_VALUE_HERE" "Database connection URL"
create_secret "DB_USERNAME" "YOUR_VALUE_HERE" "Database username"
create_secret "DB_PASSWORD" "YOUR_VALUE_HERE" "Database password"
create_secret "DB_NAME" "YOUR_VALUE_HERE" "Database name"

# --- Kakao OAuth Configuration ---
create_secret "KAKAO_CLIENT_ID" "YOUR_VALUE_HERE" "Kakao OAuth client ID"
create_secret "KAKAO_CLIENT_SECRET" "YOUR_VALUE_HERE" "Kakao OAuth client secret"
create_secret "KAKAO_REDIRECT_URI" "YOUR_VALUE_HERE" "Kakao OAuth redirect URI"
create_secret "KAKAO_FRONTEND_REDIRECT" "YOUR_VALUE_HERE" "Kakao OAuth frontend redirect URL"
create_secret "KAKAO_REST_API_KEY" "YOUR_VALUE_HERE" "Kakao REST API key"

# --- JWT Configuration ---
create_secret "JWT_SECRET" "YOUR_VALUE_HERE" "JWT signing secret"

# --- Zoom Configuration ---
create_secret "ZOOM_ACCOUNT_ID" "YOUR_VALUE_HERE" "Zoom account ID"
create_secret "ZOOM_CLIENT_ID" "YOUR_VALUE_HERE" "Zoom client ID"
create_secret "ZOOM_CLIENT_SECRET" "YOUR_VALUE_HERE" "Zoom client secret"

# --- AWS Configuration ---
create_secret "AWS_REGION" "YOUR_VALUE_HERE" "AWS region for S3"
create_secret "AWS_S3_ENABLED" "YOUR_VALUE_HERE" "AWS S3 enabled flag"
create_secret "AWS_S3_BUCKET_NAME" "YOUR_VALUE_HERE" "AWS S3 bucket name"
create_secret "AWS_S3_ENDPOINT" "YOUR_VALUE_HERE" "AWS S3 endpoint URL"
create_secret "AWS_S3_DB_BACKUP" "YOUR_VALUE_HERE" "AWS S3 DB backup bucket"

# --- AI Configuration ---
create_secret "AI_API_KEY" "YOUR_VALUE_HERE" "AI service API key"
create_secret "AI_DB_URL" "YOUR_VALUE_HERE" "AI database URL"
create_secret "GEMINI_API_KEY" "YOUR_VALUE_HERE" "Gemini API key"
create_param  "GEMINI_MODEL" "YOUR_VALUE_HERE" "Gemini model name"

# --- Firebase Configuration ---
create_secret "FIREBASE_SERVICE_ACCOUNT" "YOUR_VALUE_HERE" "Firebase service account JSON"

# --- Recommendation Scheduler Configuration ---
create_param  "ENABLE_RECO_SCHEDULER" "YOUR_VALUE_HERE" "Enable recommendation scheduler (true/false)"
create_param  "RECO_SCHEDULER_CRON" "YOUR_VALUE_HERE" "Recommendation scheduler cron expression"
create_param  "RECO_SCHEDULER_TZ" "YOUR_VALUE_HERE" "Recommendation scheduler timezone"
create_param  "RECO_SCHEDULER_SEARCH_K" "YOUR_VALUE_HERE" "Recommendation scheduler search K"
create_param  "RECO_SCHEDULER_TOP_K" "YOUR_VALUE_HERE" "Recommendation scheduler top K"

echo ""
echo "=========================================="
echo "All secrets created/updated successfully!"
echo "Total: 29 parameters for /${PROJECT}/${ENV}/"
echo "=========================================="
