/**
 * Smoke 테스트
 * 목적: 기본 기능 정상 동작 확인 (저부하)
 */
import { sleep } from 'k6';
import { config, thresholds, loadStages } from '../config.js';
import {
  apiGet, apiPost, apiPut,
  checkResponse, extractData, thinkTime, randomItem,
  initAuth, getAccessToken
} from '../helpers.js';

export const options = {
  stages: loadStages.smoke,
  thresholds: {
    http_req_duration: [`p(95)<${thresholds.read.p95}`],
    errors: [`rate<${thresholds.errorRate}`],
  },
};

// 테스트 시작 시 토큰 초기화
export function setup() {
  const hasAuth = initAuth();
  return { hasAuth };
}

export default function (data) {
  // 1. Health Check
  const healthRes = apiGet('/health');
  checkResponse(healthRes, 200, 'Health');

  thinkTime(1, 2);

  // 2. 공개 API - 추천 모임 (비로그인)
  const recommendRes = apiGet('/recommendations/meetings');
  checkResponse(recommendRes, 200, 'Recommendations');

  thinkTime(1, 2);

  // 3. 공개 API - 모임 목록
  const meetingsRes = apiGet('/meetings?size=10');
  checkResponse(meetingsRes, 200, 'Meeting List');

  const meetingsData = extractData(meetingsRes);
  if (meetingsData && meetingsData.items && meetingsData.items.length > 0) {
    thinkTime(1, 2);

    // 4. 모임 상세 조회
    const meetingId = meetingsData.items[0].meetingId;
    const detailRes = apiGet(`/meetings/${meetingId}`);
    checkResponse(detailRes, 200, 'Meeting Detail');
  }

  thinkTime(1, 2);

  // 5. 공개 API - 모임 검색
  const keyword = randomItem(config.searchKeywords);
  const searchRes = apiGet(`/meetings/search?keyword=${encodeURIComponent(keyword)}&size=10`);
  checkResponse(searchRes, 200, 'Meeting Search');

  thinkTime(1, 2);

  // 6. 공개 API - 장르 정책
  const genresRes = apiGet('/policies/reading-genres');
  checkResponse(genresRes, 200, 'Reading Genres');

  // === 인증 필요 API (토큰이 있을 경우만) ===
  if (data.hasAuth) {
    thinkTime(1, 2);

    // 7. 내 프로필 조회
    const profileRes = apiGet('/users/me', {}, true);
    checkResponse(profileRes, 200, 'My Profile');

    thinkTime(1, 2);

    // 8. 내 모임 목록
    const myMeetingsRes = apiGet('/users/me/meetings?status=ACTIVE&size=10', {}, true);
    checkResponse(myMeetingsRes, 200, 'My Meetings');

    thinkTime(1, 2);

    // 9. 알림 확인
    const unreadRes = apiGet('/notifications/unread', {}, true);
    checkResponse(unreadRes, 200, 'Unread Notifications');
  }

  sleep(1);
}
