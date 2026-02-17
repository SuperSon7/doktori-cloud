# 부하테스트 시나리오

## 테스트 대상 시스템 개요

- **서비스**: 독토리(Doktori) - 독서 모임 플랫폼 백엔드
- **기술 스택**: Spring Boot 3.x, MySQL, FCM, SSE, S3, Kakao Book API, Zoom API, AI 검증 API
- **인증**: JWT (Access 60분, Refresh 14일, Cookie 기반) + Kakao OAuth
- **비동기**: Virtual Thread 기반 `notificationExecutor` (FCM 전송용)
- **Context Path**: `/api`

---

## 공개 엔드포인트 정리 (SecurityConfig + SecurityPaths 기준)

| 엔드포인트 | 인증 |
|-----------|------|
| `GET /api/health` | 불필요 |
| `/api/oauth/**` | 불필요 |
| `/api/auth/**` | 불필요 |
| `GET /api/policies/reading-genres` | 불필요 |
| `GET /api/meetings` | 불필요 |
| `GET /api/meetings/{id}` | 불필요 (선택적 인증 — 참여 상태 표시용) |
| `GET /api/meetings/search` | 불필요 |
| `GET /api/recommendations/meetings` | 불필요 (선택적 인증 — 개인화 추천용) |
| 그 외 모든 엔드포인트 | JWT 필수 |

> **참고**: `GET /api/policies/reading-volumes`, `GET /api/policies/reading-purposes`는 SecurityPaths에 포함되어 있지 않으므로 JWT 필요.

---

## A. 서비스 관점 시나리오 (사용자 여정 기반)

### 시나리오 1: 비회원 탐색 흐름

| 단계 | API | 설명 |
|------|-----|------|
| 1 | `GET /api/health` | 서버 상태 확인 |
| 2 | `GET /api/recommendations/meetings` | 메인 페이지 — 비로그인 추천 모임 (최대 4개, `getRecommendedMeetingsForGuest()`) |
| 3 | `GET /api/meetings?size=10` | 모집중 모임 목록 (RECRUITING 상태만, 커서 기반 페이지네이션) |
| 4 | `GET /api/meetings?cursorId={id}&size=10` | 목록 스크롤 (2~3회 반복) |
| 5 | `GET /api/meetings/{meetingId}` | 모임 상세 조회 (비로그인이므로 `myParticipationStatus` = null) |
| 6 | `GET /api/meetings/search?keyword=소설&size=10` | 모임 검색 (책 제목 OR 모임 제목, 책 제목 매칭 우선 정렬) |
| 7 | `GET /api/meetings/search?keyword=에세이&readingGenre=ESSAY&size=10` | 필터 + 검색 조합 |

**목적**: 비로그인 사용자의 서비스 탐색 패턴 검증
**예상 비율**: 전체 트래픽의 약 40%
**Think Time**: 각 단계 사이 2~5초

> **코드 근거**: `SecurityConfig.java:53-56` permitAll 설정, `RecommendationController.java:68` userDetails == null 분기

---

### 시나리오 2: 로그인 후 일상 사용 흐름

| 단계 | API | 설명 |
|------|-----|------|
| 1 | `POST /api/auth/tokens` | Access Token 갱신 (Cookie의 Refresh Token 사용) |
| 2 | `GET /api/users/me` | 내 프로필 조회 |
| 3 | `GET /api/recommendations/meetings` | 개인화 추천 모임 (이번 주 월요일 기준, rank순 최대 4개) |
| 4 | `GET /api/users/me/meetings?status=ACTIVE&size=10` | 내 활성 모임 목록 (RECRUITING + FINISHED 상태) |
| 5 | `GET /api/users/me/meetings/today` | 오늘의 모임 확인 (페이지네이션 없음, 전체 반환) |
| 6 | `GET /api/users/me/meetings/{meetingId}` | 모임 상세 — 회차별 독후감 상태, meetingLink 공개 여부 포함 |
| 7 | `GET /api/notifications/unread` | 읽지 않은 알림 존재 여부 (최근 3일) |
| 8 | `GET /api/notifications` | 알림 목록 조회 (최근 3일) |
| 9 | `PUT /api/notifications/{notificationId}` | 알림 읽음 처리 |

**목적**: 기존 회원의 핵심 사용 패턴 검증
**예상 비율**: 전체 트래픽의 약 35%
**Think Time**: 각 단계 사이 3~8초

> **코드 근거**: `MeetingService.java:271-294` activeOnly 분기, `NotificationService.java:38` RECENT_DAYS = 3

---

### 시나리오 3: 모임 생성 + 참여 흐름

| 단계 | API | 설명 |
|------|-----|------|
| 1 | `GET /api/policies/reading-genres` | 장르 목록 조회 (공개) |
| 2 | `GET /api/books?query={keyword}&page=1&size=10` | 도서 검색 (Kakao Book API 프록시) |
| 3 | `POST /api/uploads/presigned-url` | 모임 이미지 S3 Presigned URL 발급 |
| 4 | `POST /api/meetings` | 모임 생성 (Meeting + MeetingMember(리더) + MeetingRound[] 일괄 생성) |
| 5 | `GET /api/meetings/{meetingId}` | 생성된 모임 상세 확인 |
| --- | **다른 사용자 관점** | |
| 6 | `GET /api/meetings/{meetingId}` | 모임 상세 조회 |
| 7 | `POST /api/meetings/{meetingId}/participations` | 모임 참여 신청 (현재 정책: 즉시 승인, currentCount 증가) |

**목적**: 쓰기 작업의 동시성 검증 — 특히 `joinMeeting()`의 정원 체크(`currentCount >= capacity`) 레이스 컨디션
**예상 비율**: 전체 트래픽의 약 10%
**Think Time**: 단계 1~3 사이 5~15초, 나머지 2~5초

> **코드 근거**: `MeetingService.java:214` 정원 체크, `MeetingService.java:242` incrementCurrentCount() — 동시 요청 시 초과 가입 가능성

---

### 시나리오 4: 독후감 제출 흐름

| 단계 | API | 설명 |
|------|-----|------|
| 1 | `GET /api/users/me/meetings/{meetingId}` | 모임 상세 (현재 라운드, 독후감 상태 확인) |
| 2 | `GET /api/meeting-rounds/{roundId}/book-reports/me` | 내 독후감 조회 |
| 3 | `POST /api/meeting-rounds/{roundId}/book-reports` | 독후감 제출 (하루 3회 제한, REJECTED 시 재제출 가능) |
| 4 | `GET /api/meeting-rounds/{roundId}/book-reports/me` | 제출 후 상태 확인 (AI 검증 대기 → APPROVED/REJECTED) |

**목적**: 독후감 제출 → AI 검증 비동기 파이프라인 부하 검증
**예상 비율**: 전체 트래픽의 약 5%
**Think Time**: 독후감 작성 30~120초, 단계 4는 5~10초 후 폴링

> **코드 근거**: `BookReportService.java:33` DAILY_SUBMISSION_LIMIT = 3, `AiValidationService.java:38-39` TIMEOUT 30초 + MAX_RETRY 3, `AiValidationService.java:69` `.subscribe()` — fire-and-forget 방식

---

### 시나리오 5: SSE 실시간 알림 구독

| 단계 | API | 설명 |
|------|-----|------|
| 1 | `GET /api/notifications/subscribe` | SSE 연결 수립 (`text/event-stream`) |
| 2 | (연결 유지 최대 30분) | 이벤트 수신 대기 (SSE_TIMEOUT = 30분) |
| 3 | `GET /api/notifications/unread` | 주기적 폴링 (30초 간격, 보조 확인용) |

**목적**: 동시 SSE 연결 수 한계 및 서버 리소스 소비 검증
**예상 비율**: 전체 트래픽의 약 10%
**핵심 측정**: 동시 연결 수, 메모리 사용량 (ConcurrentHashMap 기반 `emitters`), 재연결 시 기존 emitter 정리

> **코드 근거**: `SseEmitterService.java:17` SSE_TIMEOUT = 30분, `SseEmitterService.java:18` `ConcurrentHashMap<Long, SseEmitter>` — 사용자당 1개 연결만 유지, `SseEmitterService.java:21-23` 기존 연결 complete 후 교체

---

## B. 성능 개선 관점 시나리오 (코드 기반 병목 타겟)

### 시나리오 6: 모임 검색 서브쿼리 부하

```
타겟: MeetingRepositoryImpl.searchMeetings() — 이중 서브쿼리
```

| 설정 | 값 |
|------|-----|
| 대상 API | `GET /api/meetings/search?keyword={keyword}&size=10` |
| VUser | 50 → 100 → 200 → 500 (Ramp-up) |
| 키워드 풀 | 일반 키워드 30개 + 한글 2자 이하 짧은 검색어 10개 |
| 커서 페이지네이션 | 3페이지까지 순차 요청 |
| 측정 포인트 | 응답시간 P50/P95/P99, DB 슬로우 쿼리 |

**병목 원인** (`MeetingRepositoryImpl.java:200-226`):
- `buildSearchCondition()`: `MeetingRound → Book` JOIN 서브쿼리로 책 제목 LIKE 검색
- `buildBookTitleMatchOrder()`: 정렬을 위해 동일한 서브쿼리를 **한번 더** 실행
- 즉, 검색 요청 1건당 **동일한 서브쿼리가 2회** 실행됨
- `cb.lower()` + `LIKE '%keyword%'` → 인덱스 Full Scan 유발

---

### 시나리오 7: 오늘의 모임 조회 — DATE() 함수 인덱스 무효화

```
타겟: MeetingRepositoryImpl.findMyTodayMeetings() — DATE 함수 호출
```

| 설정 | 값 |
|------|-----|
| 대상 API | `GET /api/users/me/meetings/today` |
| VUser | 100 → 300 → 500 (Ramp-up) |
| 시간대 | 모임 집중 시간 (19:00~21:00) 시뮬레이션 |
| 측정 포인트 | DB 쿼리 실행 시간, Slow Query 발생 여부 |

**병목 원인** (`MeetingRepositoryImpl.java:345`):
```java
cb.equal(cb.function("DATE", LocalDate.class, roundRoot.get("startAt")), today)
```
- `DATE()` 함수 적용으로 `startAt` 컬럼 인덱스 사용 불가
- 추가로 MeetingMember 서브쿼리도 결합 → 이중 서브쿼리
- 개선 방안: 범위 조건 `startAt >= today 00:00:00 AND startAt < tomorrow 00:00:00`

---

### 시나리오 8: 내 모임 목록 N+1 문제

```
타겟: MeetingService.toMyMeetingItem() — 건별 추가 쿼리
```

| 설정 | 값 |
|------|-----|
| 대상 API | `GET /api/users/me/meetings?status=ACTIVE&size=10` |
| VUser | 100 → 300 (Ramp-up) |
| 측정 포인트 | DB 쿼리 수, 응답시간 |

**병목 원인** (`MeetingService.java:436-454`):
```java
// 매 항목마다 실행 (N+1)
Meeting meeting = meetingRepository.findById(row.getMeetingId())...  // 쿼리 1
List<LocalDateTime> nextRounds = meetingRoundRepository.findNextRoundDate(...)  // 쿼리 2
```
- 목록 10건 조회 시 **추가 쿼리 20건** 발생 (findById 10건 + findNextRoundDate 10건)
- 목록 조회 쿼리 1건 포함 총 21건의 쿼리 실행

---

### 시나리오 9: 내 모임 상세 조회 — 회차별 독후감 조회

```
타겟: MeetingService.getMyMeetingDetail() → toRoundDetail() 반복 호출
```

| 설정 | 값 |
|------|-----|
| 대상 API | `GET /api/users/me/meetings/{meetingId}` |
| VUser | 100 → 300 (Ramp-up) |
| 데이터 조건 | 5~8회차 모임 기준 |
| 측정 포인트 | DB 쿼리 수, 응답시간 |

**병목 원인** (`MeetingService.java:378-379`):
```java
// 매 회차(round)마다 실행
bookReportRepository.findByUserIdAndMeetingRoundIdAndDeletedAtIsNull(userId, round.getId());
```
- 8회차 모임이면 독후감 조회 쿼리 8건 추가 발생
- 기본 쿼리(모임 + 회차 + 참여자 + ReadingGenre) 4건 포함 총 12건

---

### 시나리오 10: 독후감 제출 + AI 검증 동시성

```
타겟: AiValidationService.validate() — WebClient fire-and-forget + 재시도
```

| 설정 | 값 |
|------|-----|
| 대상 API | `POST /api/meeting-rounds/{roundId}/book-reports` |
| VUser | 30 → 50 → 100 (Ramp-up) |
| 시나리오 | 동일 라운드에 다수 사용자 동시 제출 |
| 측정 포인트 | API 응답시간, AI 검증 완료율, AI API 응답 지연 |

**병목 원인** (`AiValidationService.java:47-69`):
- `.subscribe()` fire-and-forget → API 응답은 빠르지만 AI 검증 요청이 백그라운드 누적
- 30초 타임아웃 × 3회 재시도 (backoff 2초~10초) → AI 서비스 장애 시 최악 ~90초간 리소스 점유
- `.subscribe()`는 별도 스레드풀 지정 없이 Reactor 기본 스케줄러 사용 → Netty EventLoop 영향 가능

**확인 사항**: AI 서비스 지연/장애 시 WebClient 연결 풀 고갈 여부, Retry Storm 발생 여부

---

### 시나리오 11: 모임 참여 신청 — 정원 레이스 컨디션

```
타겟: MeetingService.joinMeeting() — 동시 참여 시 정원 초과
```

| 설정 | 값 |
|------|-----|
| 대상 API | `POST /api/meetings/{meetingId}/participations` |
| VUser | 동일 모임에 20~50명 동시 요청 |
| 데이터 조건 | capacity = 8, currentCount = 7 (잔여 1석) |
| 측정 포인트 | 최종 currentCount, 실제 승인된 멤버 수 |

**병목 원인** (`MeetingService.java:213-247`):
```java
if (meeting.getCurrentCount() >= meeting.getCapacity()) { throw... }  // 체크
meeting.incrementCurrentCount();  // 증가
```
- 체크와 증가 사이 다른 트랜잭션이 끼어들 수 있음 (Read-then-Write 패턴)
- DB 레벨 락(SELECT FOR UPDATE) 없이 JPA 엔티티의 메모리 값으로 비교
- 정원 8명 모임에 9~10명 이상 가입될 수 있음

---

### 시나리오 12: SSE + FCM 알림 대량 발송

```
타겟: NotificationService.createAndSendBatch() + SseEmitterService + FcmService
```

| 설정 | 값 |
|------|-----|
| SSE 연결 | 동시 200 ~ 500개 연결 유지 |
| 알림 트리거 | 독후감 검증 완료 알림 대량 발생 시뮬레이션 |
| 측정 포인트 | SSE 이벤트 전달 지연, FCM 배치 처리 시간, 메모리 사용량 |

**구현 특성**:
- SSE: 사용자당 1개 연결 (`ConcurrentHashMap`), 30분 타임아웃
- FCM: Virtual Thread 기반 `notificationExecutor` (`Executors.newVirtualThreadPerTaskExecutor()`), 500건 배치
- `createAndSendBatch()`: DB 저장 → SSE 순차 발송 → FCM @Async 발송
- `NotificationService.java:101` `saveAll(notifications)` — 대량 알림 일괄 INSERT

**확인 사항**: SSE IOException 발생 시 emitter 정리, FCM 배치 실패 시 invalid token cleanup 정상 동작

---

### 시나리오 13: 도서 검색 — 외부 API 의존성

```
타겟: BookSearchServiceImpl → KakaoBookClient — 외부 API 호출
```

| 설정 | 값 |
|------|-----|
| 대상 API | `GET /api/books?query={keyword}&page=1&size=10` |
| VUser | 50 → 100 → 200 (Ramp-up) |
| 측정 포인트 | Kakao API 응답시간, 에러율, 서버 전체 응답시간 영향 |

**구현 특성** (`BookSearchServiceImpl.java`):
- Kakao Book API를 동기적으로 호출 — 캐싱 레이어 없음
- 동일 검색어 반복 요청 시에도 매번 외부 API 호출
- Kakao API 장애/지연 시 서버 스레드가 블로킹됨

---

## C. 테스트 실행 계획

### 단계별 부하 수준

| 단계 | 목표 | 동시 사용자 | 지속 시간 |
|------|------|------------|----------|
| **Smoke** | 기능 정상 동작 확인 | 1~5 | 1분 |
| **Load** | 일반 트래픽 처리 능력 | 50~100 | 10분 |
| **Stress** | 한계점 확인 | 200~500 | 15분 |
| **Spike** | 급격한 트래픽 대응 | 100 → 500 → 100 | 5분 |
| **Soak** | 장시간 안정성 (메모리 누수, SSE 연결 누수 등) | 50 | 60분 |

### 핵심 SLO 기준

| 지표 | 목표 |
|------|------|
| 응답시간 P95 | < 500ms (읽기), < 1000ms (쓰기) |
| 응답시간 P99 | < 1500ms |
| 에러율 | < 1% |
| 처리량 | 최소 100 RPS 이상 |

### 모니터링 대상

- **애플리케이션**: Prometheus/Actuator 메트릭 (JVM heap, GC, HikariCP 커넥션풀, Virtual Thread 수)
- **데이터베이스**: Slow Query Log, Connection Pool 사용률, Lock Wait, Deadlock
- **외부 서비스**: Kakao Book API 응답시간/에러율, AI 검증 API 응답시간/에러율
- **인프라**: CPU, Memory, Network I/O

### 테스트 준비사항

1. **테스트 데이터**: 모임 100+개, 사용자 500+명, 회차/독후감 다수 사전 생성
2. **JWT 토큰**: 테스트용 사용자 JWT 사전 발급 (만료 고려)
3. **외부 API Mock**: Kakao Book API, AI 검증 API는 Mock 서버 또는 실제 서비스 선택
4. **SSE 클라이언트**: SSE 연결 유지 가능한 부하 도구 사용 (k6, Gatling 등)

---

## D. k6 테스트 코드 구현

### 코드 위치

```
/Cloud/load-tests/k6/
├── config.js           # 환경설정, SLO 임계값, 부하 단계 정의
├── helpers.js          # API 헬퍼 함수, 토큰 자동 갱신
├── scenarios/
│   ├── smoke.js        # 기본 기능 확인 (5 VU, 1분)
│   ├── load.js         # 일반 부하 (50→100 VU, 16분)
│   ├── stress.js       # 한계점 테스트 (100→500 VU)
│   ├── spike.js        # 스파이크 테스트 (100→500→100)
│   ├── soak.js         # 장시간 안정성 (50 VU, 1시간)
│   ├── guest-flow.js   # 비회원 탐색 흐름
│   ├── user-flow.js    # 로그인 사용자 흐름
│   ├── meeting-search.js    # 검색 성능 테스트
│   ├── join-meeting.js      # 모임 참여 레이스 컨디션 테스트
│   ├── today-meetings.js    # 오늘의 모임 DATE() 함수 성능
│   ├── my-meetings-n1.js    # N+1 쿼리 문제 검증
│   ├── image-upload.js      # S3 이미지 업로드
│   ├── create-meeting.js    # 모임 생성 전체 흐름
│   ├── notification.js      # SSE + 알림 API 테스트
│   └── cache-test.js        # Nginx 캐시 HIT 검증
└── scripts/
    ├── setup.sh        # k6 설치
    ├── run-single.sh   # 단일 시나리오 실행
    └── run-all.sh      # 전체 시나리오 실행
```

---

### 환경변수 설정

```bash
# 필수 - 대상 서버 URL
export BASE_URL="https://your-api-server.com/api"

# 인증 방식 (둘 중 하나 선택)
# 방법 1: Access Token 직접 제공
export JWT_TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI..."

# 방법 2: Refresh Token으로 자동 갱신
export REFRESH_TOKEN="your-refresh-token"

# 선택 - 테스트 데이터 ID
export TEST_MEETING_ID=1
export TEST_ROUND_ID=1
```

**토큰 자동 갱신**: `helpers.js`의 `initAuth()`가 시작 시 Refresh Token으로 Access Token을 발급받고, 401 응답 시 자동으로 갱신합니다.

---

### 실행 명령어

#### 기본 실행

```bash
# Smoke 테스트
k6 run scenarios/smoke.js

# Load 테스트
k6 run scenarios/load.js

# Stress 테스트
k6 run scenarios/stress.js
```

#### VU 및 시간 오버라이드

```bash
# VU 수 지정
k6 run --vus 200 --duration 5m scenarios/stress.js

# 1000명으로 스트레스 테스트
k6 run --vus 1000 --duration 10m scenarios/stress.js
```

#### HTML 리포트 생성

```bash
# Web Dashboard + HTML Export
K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT=report.html \
  k6 run --vus 500 --duration 5m scenarios/stress.js

# 리포트는 report.html에 저장됨
```

---

### 시나리오별 설명

#### 1. smoke.js - 기본 기능 확인
- **목적**: 배포 후 API 정상 동작 확인
- **설정**: 5 VU, 1분
- **테스트 내용**: 헬스체크, 추천 모임, 모임 목록, 검색

#### 2. load.js - 일반 부하 테스트
- **목적**: 일반적인 트래픽 패턴 시뮬레이션
- **설정**: 50→100 VU, 총 16분 (ramp-up → steady → ramp-down)
- **트래픽 비율**:
  - 35%: 비회원 탐색 (guest-flow)
  - 30%: 로그인 사용자 (user-flow)
  - 15%: 검색
  - 10%: 도서 검색
  - 10%: 이미지 업로드

#### 3. stress.js - 한계점 테스트
- **목적**: 시스템 한계 확인
- **설정**: 100→200→300→500 VU, 점진적 증가
- **트래픽 비율**:
  - 50%: 공개 API
  - 30%: 인증 API (인증 시)
  - 10%: 검색 집중
  - 10%: 이미지 업로드

#### 4. spike.js - 급격한 트래픽 대응
- **목적**: 갑작스러운 트래픽 급증 대응력 확인
- **설정**: 100→500→100 VU, 급격한 스파이크

#### 5. soak.js - 장시간 안정성
- **목적**: 메모리 누수, 커넥션 풀 누수 등 확인
- **설정**: 50 VU, 1시간

#### 6. cache-test.js - Nginx 캐시 HIT 검증
- **목적**: 캐시 효과 측정
- **특징**:
  - 고정 URL 사용 (쿼리스트링 고정)
  - 인증 헤더 없음 (캐시 가능하도록)
  - 워밍업 단계 후 캐시 HIT 테스트
- **메트릭**:
  - `fast_responses`: 50ms 이하 응답 비율 (캐시 HIT 추정)
  - `cache_hit_duration`: 빠른 응답 시간 분포
  - `cache_miss_duration`: 느린 응답 시간 분포

#### 7. create-meeting.js - 모임 생성 흐름
- **목적**: 전체 모임 생성 파이프라인 테스트
- **흐름**:
  1. `GET /books?query={keyword}` - 도서 검색 (Kakao API)
  2. `POST /uploads/presigned-url` - 이미지 URL 발급
  3. `PUT S3` - 이미지 업로드
  4. `POST /meetings` - 모임 생성

#### 8. notification.js - 알림 시스템 테스트
- **목적**: SSE 연결 및 알림 API 성능 검증
- **시나리오**:
  - `sse_connections`: SSE 연결 유지 (50→200 VU)
  - `notification_api`: 알림 API 호출 (20→50 VU)
- **메트릭**:
  - `sse_connect_duration`: SSE 연결 시간
  - `sse_active_connections`: 활성 연결 수
  - `notification_list_duration`: 알림 목록 조회 시간

#### 9. join-meeting.js - 레이스 컨디션 테스트
- **목적**: 정원 초과 가입 버그 검증
- **방법**: 잔여 1석 모임에 20명 동시 참여 신청

---

### 커스텀 메트릭

각 시나리오에서 수집하는 주요 메트릭:

| 메트릭 | 타입 | 설명 |
|--------|------|------|
| `search_duration` | Trend | 검색 API 응답 시간 |
| `meeting_list_duration` | Trend | 모임 목록 조회 시간 |
| `today_meetings_duration` | Trend | 오늘의 모임 조회 시간 |
| `my_meetings_duration` | Trend | 내 모임 목록 조회 시간 |
| `presigned_url_duration` | Trend | S3 URL 발급 시간 |
| `s3_upload_duration` | Trend | S3 업로드 시간 |
| `sse_connect_duration` | Trend | SSE 연결 시간 |
| `fast_responses` | Rate | 50ms 이하 응답 비율 (캐시 HIT) |

---

### S3 테스트 데이터 정리

이미지 업로드 테스트 시 `loadtest_` 접두사가 붙은 파일이 생성됩니다.

```bash
# 테스트 파일 목록 확인
aws s3 ls s3://your-bucket/PROFILE/ | grep loadtest_
aws s3 ls s3://your-bucket/MEETING/ | grep loadtest_

# 테스트 파일 삭제
aws s3 rm s3://your-bucket/PROFILE/ --recursive --exclude "*" --include "loadtest_*"
aws s3 rm s3://your-bucket/MEETING/ --recursive --exclude "*" --include "loadtest_*"
```

---

### 실행 순서 권장

1. **Smoke** → 기능 정상 확인
2. **Load** → 일반 부하 성능 확인
3. **Stress** → 한계점 확인
4. **Cache-test** → 캐시 효과 검증 (별도 실행)
5. **Soak** → 장시간 안정성 확인 (선택)

### 주요 관찰 지표

| 테스트 | 관찰 지표 |
|--------|----------|
| Smoke | 에러 발생 여부, 응답 코드 |
| Load | P95 응답시간, 에러율, 처리량(RPS) |
| Stress | 한계 VU 수, 에러 급증 시점, P99 응답시간 |
| Cache | `fast_responses` 비율 (목표: 80% 이상) |
| Soak | 메모리 사용량 추이, 응답시간 변화 |