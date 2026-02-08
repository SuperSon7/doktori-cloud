/**
 * 모임 생성 부하 테스트
 *
 * 흐름:
 * 1. GET /books?query={keyword} → 도서 검색 (Kakao API)
 * 2. POST /uploads/presigned-url → 모임 이미지 URL 발급
 * 3. PUT S3 → 이미지 업로드
 * 4. POST /meetings → 모임 생성
 *
 * 테스트 포인트:
 * - Kakao Book API 의존성
 * - S3 업로드 성능
 * - 모임 생성 트랜잭션 (Meeting + MeetingMember + MeetingRound 일괄)
 */
import http from 'k6/http';
import { group, check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { config } from '../config.js';
import {
  apiGet, apiPost, checkResponse, extractData,
  initAuth, randomItem, randomInt, thinkTime
} from '../helpers.js';

// 커스텀 메트릭
const bookSearchDuration = new Trend('book_search_duration', true);
const meetingCreateDuration = new Trend('meeting_create_duration', true);
const createSuccess = new Counter('meeting_create_success');
const createFailed = new Counter('meeting_create_failed');

export const options = {
  scenarios: {
    create_meeting: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '1m', target: 5 },
        { duration: '2m', target: 10 },
        { duration: '2m', target: 20 },
        { duration: '1m', target: 0 },
      ],
    },
  },
  thresholds: {
    book_search_duration: ['p(95)<2000'],  // Kakao API 의존
    meeting_create_duration: ['p(95)<1500'],
    http_req_failed: ['rate<0.05'],
  },
};

// 테스트용 도서 검색 키워드
const bookKeywords = ['해리포터', '아몬드', '데미안', '어린왕자', '사피엔스', '코스모스'];

// 장르 ID (실제 DB 값에 맞게 수정 필요)
const genreIds = [1, 2, 3, 4, 5];

// 요일
const daysOfWeek = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];

export function setup() {
  const hasAuth = initAuth();
  if (!hasAuth) {
    console.error('모임 생성은 인증이 필요합니다.');
  }
  return { hasAuth };
}

export default function (data) {
  if (!data.hasAuth) {
    sleep(1);
    return;
  }

  let book = null;
  let presignedUrl = null;
  let imageKey = null;

  group('모임 생성 흐름', function () {
    // 1. 도서 검색
    group('도서 검색', function () {
      const keyword = randomItem(bookKeywords);
      const start = Date.now();

      const res = apiGet(`/books?query=${encodeURIComponent(keyword)}&page=1&size=5`, {}, true);

      bookSearchDuration.add(Date.now() - start);

      if (res.status === 200) {
        const resData = extractData(res);
        if (resData && resData.items && resData.items.length > 0) {
          book = randomItem(resData.items);
        }
      }
    });

    if (!book) {
      console.log('도서 검색 실패 - 모임 생성 건너뜀');
      createFailed.add(1);
      return;
    }

    thinkTime(1, 2);

    // 2. 이미지 Presigned URL 발급
    group('이미지 URL 발급', function () {
      const res = apiPost('/uploads/presigned-url', {
        directory: 'MEETING',
        fileName: `loadtest_meeting_${Date.now()}.jpg`,
        contentType: 'image/jpeg',
        fileSize: 100 * 1024,
      }, true);

      if (res.status === 200) {
        const resData = extractData(res);
        presignedUrl = resData.presignedUrl;
        imageKey = resData.key;
      }
    });

    thinkTime(1, 2);

    // 3. S3 이미지 업로드
    if (presignedUrl) {
      group('이미지 업로드', function () {
        const dummyData = new ArrayBuffer(100 * 1024);
        http.put(presignedUrl, dummyData, {
          headers: { 'Content-Type': 'image/jpeg' },
          tags: { name: 's3_upload' },
        });
      });
    }

    thinkTime(1, 2);

    // 4. 모임 생성
    group('모임 생성', function () {
      const now = new Date();
      const firstRoundDate = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000); // 7일 후
      const recruitmentDeadline = new Date(now.getTime() + 5 * 24 * 60 * 60 * 1000); // 5일 후

      const formatDate = (d) => d.toISOString().split('T')[0];

      const meetingData = {
        title: `[부하테스트] 모임 ${Date.now()}`,
        description: '부하테스트용 모임입니다. 테스트 후 삭제됩니다.',
        readingGenreId: randomItem(genreIds),
        capacity: randomInt(3, 8),
        roundCount: randomInt(1, 4),
        leaderIntro: '부하테스트 리더입니다.',
        leaderIntroSavePolicy: false,
        meetingImagePath: imageKey,
        firstRoundAt: formatDate(firstRoundDate),
        recruitmentDeadline: formatDate(recruitmentDeadline),
        time: {
          startTime: '19:00',
          endTime: '20:30',
        },
        rounds: [
          { roundNo: 1, date: formatDate(firstRoundDate) },
        ],
        booksByRound: [
          {
            roundNo: 1,
            book: {
              title: book.title,
              authors: book.authors,
              publisher: book.publisher,
              thumbnailUrl: book.thumbnailUrl,
              publishedAt: book.publishedAt,
              isbn13: book.isbn13,
            },
          },
        ],
      };

      const start = Date.now();
      const res = apiPost('/meetings', meetingData, true);
      meetingCreateDuration.add(Date.now() - start);

      const success = check(res, {
        'Meeting create - status 201': (r) => r.status === 201,
      });

      if (success) {
        createSuccess.add(1);
        const resData = extractData(res);
        console.log(`모임 생성 성공: ID ${resData?.meetingId}`);
      } else {
        createFailed.add(1);
        console.log(`모임 생성 실패: ${res.status} - ${res.body}`);
      }
    });
  });

  thinkTime(3, 5);
}
