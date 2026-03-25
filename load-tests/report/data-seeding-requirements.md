# 부하테스트용 데이터 시딩 요구사항

> 현재 DB에 데이터가 거의 없어 조회 부하가 비현실적으로 낮음.
> 실제 서비스 규모를 시뮬레이션하려면 아래 데이터가 필요함.

## 현재 상태

| 테이블 | 현재 | 필요 | 비고 |
|--------|------|------|------|
| users | 500 (테스트 유저) | **충분** | DevDataInitializer가 생성 |
| reading_genres | ? (lookup) | 확인 필요 | 코드: NOVEL, ESSAY, ECONOMY 등 |
| books | 거의 없음 | **1,000** | 모임/독후감/채팅방에 참조됨 |
| meetings | 거의 없음 | **5,000** | 핵심 — 목록/검색/상세/페이지네이션 |
| meeting_rounds | 거의 없음 | **15,000** | 모임당 1~4 라운드 |
| meeting_members | 거의 없음 | **25,000** | 모임당 3~8명 |
| book_reports | 거의 없음 | **10,000** | 라운드별 독후감 |
| chatting_rooms | 거의 없음 | **2,000** | 채팅방 목록/페이지네이션 |
| chatting_room_members | 거의 없음 | **8,000** | 방당 2~6명 |
| notifications | 거의 없음 | **50,000** | 유저당 ~100건 (3일치) |

## 엔티티 관계도

```
User (500명, 이미 있음)
  │
  ├── Meeting (리더로 생성)
  │     ├── readingGenreId → ReadingGenre (lookup)
  │     ├── leaderUser → User
  │     ├── status: RECRUITING / FINISHED / CANCELED
  │     ├── capacity: 3~8
  │     ├── currentCount: 참여 인원
  │     │
  │     ├── MeetingRound (1~4개)
  │     │     ├── book → Book
  │     │     ├── roundNo: 1,2,3,4
  │     │     ├── status: SCHEDULED / DONE / CANCELED
  │     │     ├── startAt, endAt: 날짜
  │     │     │
  │     │     └── BookReport (라운드별 참여자 수)
  │     │           ├── user → User
  │     │           ├── content: TEXT
  │     │           └── status: enum
  │     │
  │     └── MeetingMember (3~8명)
  │           ├── user → User
  │           ├── role: LEADER / MEMBER
  │           └── status: PENDING / APPROVED / REJECTED / LEFT / KICKED
  │
  ├── ChattingRoom (생성자)
  │     ├── topic, description
  │     ├── book → Book
  │     ├── capacity: 2~6
  │     ├── status: WAITING / CHATTING / ENDED / CANCELLED
  │     ├── duration: 30 (분)
  │     │
  │     └── ChattingRoomMember (2~6명)
  │           ├── userId, nickname
  │           ├── position: AGREE / DISAGREE
  │           └── role: OWNER / PARTICIPANT
  │
  └── Notification (자동 생성)
```

## 시딩 데이터 상세

### 1. books (1,000건)

다양한 장르의 도서 데이터. ISBN은 유니크해야 함.

```
필수 필드:
- isbn13: "978XXXXXXXXXX" (unique, 13자리)
- title: "도서 제목 #{i}" 또는 실제 도서명 목록
- authors: "저자명"
- publisher: "출판사"

선택 필드:
- thumbnail_url: 기본 이미지 URL
- published_at: 과거 랜덤 날짜
- summary: 100~500자 더미 텍스트 (검색 성능에 영향)
```

### 2. meetings (5,000건)

상태 분포:
- RECRUITING: 2,000건 (검색/목록에 노출 — 가장 중요)
- FINISHED: 2,500건 (과거 데이터, 검색에 포함)
- CANCELED: 500건

```
각 모임:
- leaderUser: testuser_1 ~ testuser_500 중 랜덤 (유저당 평균 10개 모임)
- readingGenreId: 1~10 (reading_genres 테이블 ID)
- capacity: 3~8 랜덤
- currentCount: 실제 meeting_members 수와 일치
- roundCount: 1~4 랜덤
- currentRound: 1 (RECRUITING) / roundCount (FINISHED)
- title: 다양한 제목 (검색 테스트를 위해 키워드 분산)
  - "함께 읽는 {장르} 모임 #{i}"
  - "{도서명} 완독 챌린지 #{i}"
  - "주말 {장르} 독서 클럽 #{i}"
- description: 50~200자 (다양한 키워드 포함)
- meetingImagePath: "images/meetings/default.png"
- recruitmentDeadline: 미래 7~30일 (RECRUITING) / 과거 (FINISHED)
- startTime: "19:00" / "20:00" / "21:00" 랜덤
- durationMinutes: 60 / 90 / 120 랜덤
```

### 3. meeting_rounds (모임당 1~4개, 총 ~15,000건)

```
각 라운드:
- meetingId: 해당 모임
- bookId: books 1,000건 중 랜덤
- roundNo: 1, 2, 3, 4 (순차)
- status: SCHEDULED (RECRUITING 모임) / DONE (FINISHED 모임)
- startAt: 모임 시작일 기준 7일 간격
- endAt: startAt + durationMinutes
- bestMemberDetermined: false (SCHEDULED) / true (DONE)
```

### 4. meeting_members (모임당 3~8명, 총 ~25,000건)

```
각 멤버:
- meetingId: 해당 모임
- userId: testuser 중 랜덤 (같은 모임에 중복 방지)
- role: LEADER (1명, leaderUser와 동일) / MEMBER (나머지)
- status: APPROVED
- approvedAt: 과거 날짜
- memberIntro: "안녕하세요, 함께 읽어요" (50~100자)

주의: 한 유저가 여러 모임에 참여 가능하지만, 같은 모임에 중복 불가
```

### 5. book_reports (DONE 라운드 × 멤버, 총 ~10,000건)

```
각 독후감:
- userId: 해당 라운드 소속 모임의 참여자
- meetingRoundId: DONE 상태 라운드
- content: 200~1000자 더미 텍스트 (TEXT 컬럼, 크기 다양하게)
  - 실제 독후감 느낌의 텍스트 풀에서 랜덤 조합
- status: APPROVED (80%) / PENDING (20%)
- aiValidatedAt: APPROVED면 과거 날짜
- rejectionReason: null
```

### 6. chatting_rooms (2,000건)

상태 분포:
- WAITING: 1,000건 (목록에 노출)
- ENDED: 1,000건 (과거 데이터)

```
각 채팅방:
- topic: 다양한 토론 주제
  - "{도서명}의 주인공은 올바른 선택을 했는가?"
  - "{도서명}에서 가장 인상 깊은 장면은?"
  - "{장르} 장르의 미래는?"
- description: 50~200자
- bookId: books 중 랜덤
- capacity: 2~6 랜덤
- currentMemberCount: 실제 멤버 수와 일치
- duration: 30
- status: WAITING / ENDED
```

### 7. chatting_room_members (방당 2~6명, 총 ~8,000건)

```
각 멤버:
- chattingRoomId: 해당 방
- userId: testuser ID
- nickname: "testuser_{i}"
- profileImageUrl: 기본 이미지 URL
- position: AGREE (50%) / DISAGREE (50%)
- role: OWNER (1명) / PARTICIPANT (나머지)
- status: ACTIVE (WAITING 방) / DISCONNECTED (ENDED 방)
```

### 8. notifications (50,000건)

유저당 평균 100건 (3일치 시뮬레이션).

```
각 알림:
- userId: testuser 중 랜덤
- notificationTypeId: notification_types에서 랜덤
- title: 알림 타입에 맞는 제목
- message: "모임 '...'에 새 참여자가 있습니다" 등
- linkPath: "/meetings/{id}" 등
- isRead: true (70%) / false (30%)
- createdAt: 최근 3일 내 랜덤
```

## 시딩 방법 추천

### 방법 A: DevDataInitializer 확장 (추천)
기존 `DevDataInitializer`에 모임/채팅방 시딩 로직 추가.
- 장점: 앱 시작 시 자동 실행, 코드로 관리
- 단점: 백엔드 코드 수정 필요

### 방법 B: SQL 직접 실행
시딩 SQL 스크립트를 마스터에서 실행.
- 장점: 백엔드 코드 수정 없음
- 단점: FK 관계 맞추기 복잡, DB 접속 필요

### 방법 C: k6 시나리오로 API 호출
모임 생성/참여 API를 반복 호출하여 데이터 생성.
- 장점: API 검증도 겸함
- 단점: 시간 오래 걸림, 외부 API 의존 (도서 검색)

**추천: 방법 A** — `DevDataInitializer`에 `seedMeetings()`, `seedChatRooms()` 메서드 추가

## 선행 확인 필요

1. `reading_genres` 테이블에 어떤 데이터가 있는지 (ID, code, name)
2. `notification_types` 테이블 데이터
3. 현재 DB의 auto_increment 상태 (충돌 방지)

```sql
-- 마스터에서 확인
SELECT * FROM reading_genres;
SELECT * FROM notification_types;
SELECT COUNT(*) FROM meetings;
SELECT COUNT(*) FROM books;
```