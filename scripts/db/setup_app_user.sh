#!/bin/bash
set -e
# ==========================================================================
# Doktori Production - App DB User 자동 설정
# ==========================================================================
# rds_monitoring 인스턴스에서 실행, 또는 SSM send-command로 실행
#
# 사용법:
#   bash setup_app_user.sh
#
# 필요한 환경:
#   - mysql client 설치됨
#   - AWS CLI + SSM Parameter Store 접근 가능
#   - RDS 네트워크 접근 가능
# ==========================================================================

REGION=${AWS_DEFAULT_REGION:-ap-northeast-2}
PROJECT=doktori
ENV=prod

echo "=== Reading credentials from Parameter Store ==="
RDS_HOST=$(aws ssm get-parameter --name "/${PROJECT}/${ENV}/DB_URL" --with-decryption --region "$REGION" --query "Parameter.Value" --output text | sed 's|jdbc:mysql://||;s|:3306/.*||')
ADMIN_PASS=$(aws ssm get-parameter --name "/${PROJECT}/${ENV}/db/password" --with-decryption --region "$REGION" --query "Parameter.Value" --output text)
APP_PASS=$(aws ssm get-parameter --name "/${PROJECT}/${ENV}/DB_PASSWORD" --with-decryption --region "$REGION" --query "Parameter.Value" --output text)

echo "RDS Host: $RDS_HOST"

echo "=== Creating database and app user ==="
mysql -h "$RDS_HOST" -u admin -p"$ADMIN_PASS" <<SQL
CREATE DATABASE IF NOT EXISTS doktoridb
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'doktori_app'@'%' IDENTIFIED BY '$APP_PASS';

GRANT SELECT, INSERT, UPDATE, DELETE,
      CREATE, ALTER, DROP, INDEX, REFERENCES
    ON doktoridb.* TO 'doktori_app'@'%';

FLUSH PRIVILEGES;
SQL

echo "=== Verifying ==="
mysql -h "$RDS_HOST" -u admin -p"$ADMIN_PASS" -e "SHOW GRANTS FOR 'doktori_app'@'%'"
mysql -h "$RDS_HOST" -u doktori_app -p"$APP_PASS" doktoridb -e "SELECT 1 AS connected"

echo "=== Done ==="