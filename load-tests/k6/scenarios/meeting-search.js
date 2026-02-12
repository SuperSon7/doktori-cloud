/**
 * 시나리오 6: 모임 검색 서브쿼리 부하 테스트
 *
 * 병목 타겟: MeetingRepositoryImpl.searchMeetings()
 * - buildSearchCondition(): MeetingRound → Book JOIN 서브쿼리
 * - buildBookTitleMatchOrder(): 동일 서브쿼리 한번 더 실행
 * - 검색 요청 1건당 동일한 서브쿼리가 2회 실행됨
 *
 * 코드 위치: MeetingRepositoryImpl.java:200-253
 */
import { group, check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { config, thresholds } from '../config.js';
import {
  apiGet, checkResponse, extractData,
  thinkTime, randomItem, randomInt
} from '../helpers.js';

// 커스텀 메트릭
const searchDuration = new Trend('meeting_search_duration', true);
const searchRequests = new Counter('meeting_search_requests');
const searchWithFilter = new Trend('meeting_search_with_filter_duration', true);

export const options = {
  scenarios: {
    // 점진적 부하 증가
    ramping_search: {
      executor: 'ramping-vus',
      startVUs: 10,
      stages: [
        { duration: '2m', target: 50 },
        { duration: '3m', target: 100 },
        { duration: '3m', target: 200 },
        { duration: '5m', target: 500 },
        { duration: '2m', target: 0 },
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    meeting_search_duration: ['p(95)<800', 'p(99)<1500'],
    meeting_search_with_filter_duration: ['p(95)<1000', 'p(99)<2000'],
    http_req_failed: ['rate<0.01'],
  },
};

// 짧은 검색어 (인덱스 Full Scan 유발)
const shortKeywords = ['책', '삶', '사랑', '꿈', '별', '길', '밤', '숲'];

// 일반 검색어
const normalKeywords = [
  '소설', '에세이', '경제', '자기계발', '심리학', '역사', '과학', '철학',
  '해리포터', '아몬드', '데미안', '어린왕자', '1984', '사피엔스',
];

// 복합 검색어 (책 제목 + 모임 제목 동시 매칭 가능)
const complexKeywords = [
  '함께 읽는', '독서 모임', '스터디', '완독', '토론',
];

export default function () {
  const searchType = randomInt(1, 100);

  if (searchType <= 40) {
    // 40%: 일반 키워드 검색
    group('일반 키워드 검색', function () {
      const keyword = randomItem(normalKeywords);
      const start = Date.now();

      const res = apiGet(`/meetings/search?keyword=${encodeURIComponent(keyword)}&size=10`);

      const duration = Date.now() - start;
      searchDuration.add(duration);
      searchRequests.add(1);

      checkResponse(res, 200, 'Normal Search');
    });

  } else if (searchType <= 60) {
    // 20%: 짧은 키워드 검색 (성능 저하 예상)
    group('짧은 키워드 검색', function () {
      const keyword = randomItem(shortKeywords);
      const start = Date.now();

      const res = apiGet(`/meetings/search?keyword=${encodeURIComponent(keyword)}&size=10`);

      const duration = Date.now() - start;
      searchDuration.add(duration);
      searchRequests.add(1);

      check(res, {
        'Short keyword search - status 200': (r) => r.status === 200,
        'Short keyword search - under 1s': (r) => r.timings.duration < 1000,
      });
    });

  } else if (searchType <= 80) {
    // 20%: 필터 + 키워드 조합
    group('필터 조합 검색', function () {
      const keyword = randomItem(normalKeywords);
      const genre = randomItem(config.genreCodes);
      const dayOfWeek = randomItem(config.dayOfWeeks);

      const start = Date.now();
      const res = apiGet(
        `/meetings/search?keyword=${encodeURIComponent(keyword)}&readingGenre=${genre}&dayOfWeek=${dayOfWeek}&size=10`
      );

      const duration = Date.now() - start;
      searchWithFilter.add(duration);
      searchRequests.add(1);

      checkResponse(res, 200, 'Filtered Search');
    });

  } else {
    // 20%: 페이지네이션 (깊은 페이지)
    group('검색 페이지네이션', function () {
      const keyword = randomItem(normalKeywords);
      let cursorId = null;

      for (let page = 1; page <= 3; page++) {
        const params = cursorId
          ? `keyword=${encodeURIComponent(keyword)}&cursorId=${cursorId}&size=10`
          : `keyword=${encodeURIComponent(keyword)}&size=10`;

        const start = Date.now();
        const res = apiGet(`/meetings/search?${params}`);

        const duration = Date.now() - start;
        searchDuration.add(duration);
        searchRequests.add(1);

        check(res, {
          [`Page ${page} - status 200`]: (r) => r.status === 200,
          [`Page ${page} - under 800ms`]: (r) => r.timings.duration < 800,
        });

        const data = extractData(res);
        if (!data || !data.pageInfo || !data.pageInfo.hasNext) {
          break;
        }
        cursorId = data.pageInfo.nextCursorId;

        sleep(0.5);
      }
    });
  }

  thinkTime(1, 3);
}
