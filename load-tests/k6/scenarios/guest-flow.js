/**
 * 시나리오 1: 비회원 탐색 흐름
 * 목적: 비로그인 사용자의 서비스 탐색 패턴 검증
 * 예상 비율: 전체 트래픽의 약 40%
 */
import { group } from 'k6';
import { config, thresholds, loadStages } from '../config.js';
import {
  apiGet, checkResponse, extractData,
  thinkTime, randomItem, paginateWithCursor
} from '../helpers.js';

export const options = {
  stages: loadStages.load,
  thresholds: {
    http_req_duration: [`p(95)<${thresholds.read.p95}`],
    'http_req_duration{name:/health}': ['p(95)<100'],
    'http_req_duration{name:/recommendations/meetings}': ['p(95)<500'],
    'http_req_duration{name:/meetings}': ['p(95)<500'],
    'http_req_duration{name:/meetings/search}': ['p(95)<800'],
    errors: [`rate<${thresholds.errorRate}`],
  },
};

export default function () {
  group('비회원 탐색 흐름', function () {
    // 1. 서버 상태 확인
    group('Health Check', function () {
      const res = apiGet('/health');
      checkResponse(res, 200, 'Health');
    });

    thinkTime(2, 5);

    // 2. 메인 페이지 - 추천 모임 조회
    group('추천 모임', function () {
      const res = apiGet('/recommendations/meetings');
      checkResponse(res, 200, 'Recommendations');

      const data = extractData(res);
      // 비로그인 시 최대 4개 반환
      if (data && Array.isArray(data)) {
        console.log(`추천 모임 ${data.length}개 조회`);
      }
    });

    thinkTime(2, 5);

    // 3. 모집중 모임 목록 조회 + 스크롤
    let meetingIds = [];
    group('모임 목록 스크롤', function () {
      const meetings = paginateWithCursor('/meetings', { size: 10 }, 3, false);
      meetingIds = meetings.map(m => m.meetingId);
      console.log(`모임 목록 ${meetingIds.length}개 조회`);
    });

    thinkTime(2, 5);

    // 4. 모임 상세 조회
    if (meetingIds.length > 0) {
      group('모임 상세', function () {
        const meetingId = randomItem(meetingIds);
        const res = apiGet(`/meetings/${meetingId}`);
        checkResponse(res, 200, 'Meeting Detail');

        const data = extractData(res);
        if (data && data.meeting) {
          console.log(`모임 상세: ${data.meeting.title}`);
        }
      });
    }

    thinkTime(2, 5);

    // 5. 모임 검색 (키워드만)
    group('모임 검색 - 키워드', function () {
      const keyword = randomItem(config.searchKeywords);
      const res = apiGet(`/meetings/search?keyword=${encodeURIComponent(keyword)}&size=10`);
      checkResponse(res, 200, 'Search by keyword');

      const data = extractData(res);
      if (data && data.items) {
        console.log(`검색 "${keyword}": ${data.items.length}개 결과`);
      }
    });

    thinkTime(2, 5);

    // 6. 모임 검색 (키워드 + 장르 필터)
    group('모임 검색 - 필터 조합', function () {
      const keyword = randomItem(config.searchKeywords);
      const genre = randomItem(config.genreCodes);
      const res = apiGet(`/meetings/search?keyword=${encodeURIComponent(keyword)}&readingGenre=${genre}&size=10`);
      checkResponse(res, 200, 'Search with filter');

      const data = extractData(res);
      if (data && data.items) {
        console.log(`검색 "${keyword}" + ${genre}: ${data.items.length}개 결과`);
      }
    });
  });
}
