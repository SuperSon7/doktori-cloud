# EC2 로컬 MySQL → RDS 무중단 마이그레이션

## 1. 서비스 현황

### 아키텍처

독서 모임 매칭 플랫폼 **독토리(Doktori)** 의 백엔드.

- **런타임**: Spring Boot 3.5 / Java 21
- **모듈 구조**: `api` (메인 API), `chat` (채팅), `common` (공유 엔티티)
- **DB**: EC2 인스턴스 내 로컬 MySQL 8.0 (단일 인스턴스)
- **인프라**: 단일 EC2에 앱 + DB 동거 (MVP 구성)

### DB 스키마 (Flyway V1~V7, 17 테이블)

| 도메인 | 테이블 | 비고 |
|--------|--------|------|
| 사용자 | `users`, `user_accounts`, `user_preferences`, `user_stats`, `user_reading_genres`, `user_reading_purposes` | 카카오 OAuth, 온보딩 |
| 모임 | `meetings`, `meeting_members`, `meeting_rounds` | FK 체인: meeting → member → round |
| 도서 | `books`, `book_reports` | AI 독후감 검사 연동 |
| 알림 | `notification_types`, `notifications`, `user_push_tokens` | FCM 푸시 |
| 추천 | `user_meeting_recommendations` | AI 주간 추천 |
| 인증 | `refresh_tokens` | JWT refresh token |
| 코드 | `reading_volumes`, `reading_genres`, `reading_purposes` | 시드 데이터 포함 |

### DB 의존 컴포넌트

| 컴포넌트 | 주기 | 쓰기 여부 | 마이그레이션 시 영향 |
|----------|------|-----------|---------------------|
| API 서버 (HikariCP pool=40) | 상시 | Read/Write | 커넥션 전환 필요 |
| `MeetingScheduler` | 매일 00:00 | Write | 컷오버 시점 회피 가능 |
| `NotificationSchedulerService` | 매시/30분 | Write | 컷오버 시점 회피 가능 |
| AI 서버 (Python/SQLAlchemy) | 주 1회 배치 | Write | 컷오버 후 재시작 |

### 커넥션 설정

```yaml
hikari:
  maximum-pool-size: 40
  minimum-idle: 10
  connection-timeout: 3000    # 3초
  idle-timeout: 600000        # 10분
  max-lifetime: 1800000       # 30분
  pool-name: DoktoriHikariPool
```

- Prod 환경 시크릿: AWS Parameter Store (`/doktori/prod/`)
- DDL 전략: `validate` (Flyway가 스키마 관리)
- Native query 없음 — 전부 JPQL (`@Query`)

### 단일 인스턴스의 한계 (마이그레이션 동기)

| 문제 | 설명 |
|------|------|
| 단일 장애점 (SPOF) | EC2 1대에 앱+DB 동거 → EC2 장애 시 서비스 전체 중단 |
| 스케일 아웃 불가 | DB가 로컬이라 앱 인스턴스를 늘릴 수 없음 |
| 백업/복구 | 수동 mysqldump만 가능, 자동 백업·PiTR 없음 |
| v2 기능 추가 예정 | 트래픽 증가(MAU 30만 가정) 대비 DB 분리 필수 |