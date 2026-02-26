-- ==========================================================================
-- Doktori Production - App DB User 초기화
-- ==========================================================================
-- admin(master) 유저로 실행
--
-- 사용법 (rds_monitoring 인스턴스에서):
--   mysql -h <RDS_ENDPOINT> -u admin -p < init_app_user.sql
--
-- 권한 분리:
--   admin   → DB 관리 전용 (유저 생성, 스키마 변경, 백업)
--   doktori_app → 앱 런타임 + Flyway 마이그레이션
-- ==========================================================================

-- DB 생성 (없으면)
CREATE DATABASE IF NOT EXISTS doktoridb
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

-- 앱 유저 생성 (비밀번호는 SSM Parameter Store /doktori/prod/DB_PASSWORD 참조)
-- 실행 전 <APP_PASSWORD>를 실제 값으로 교체
CREATE USER IF NOT EXISTS 'doktori_app'@'%' IDENTIFIED BY '<APP_PASSWORD>';

-- DML + Flyway DDL 권한
GRANT SELECT, INSERT, UPDATE, DELETE,
      CREATE, ALTER, DROP, INDEX, REFERENCES
    ON doktoridb.* TO 'doktori_app'@'%';

FLUSH PRIVILEGES;

-- 확인
SHOW GRANTS FOR 'doktori_app'@'%';