/**
 * 시나리오 8: 내 모임 목록 N+1 문제 테스트
 *
 * 병목 타겟: MeetingService.toMyMeetingItem()
 * - 매 항목마다 meetingRepository.findById() 호출
 * - 매 항목마다 meetingRoundRepository.findNextRoundDate() 호출
 * - 목록 10건 조회 시 추가 쿼리 20건 발생 (총 21쿼리)
 *
 * 코드 위치: MeetingService.java:436-454
 */
import { group, check } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { config, thresholds } from '../config.js';
import { apiGet, checkResponse, extractData, thinkTime, initAuth } from '../helpers.js';

// 커스텀 메트릭
const myMeetingsDuration = new Trend('my_meetings_duration', true);
const myMeetingsRequests = new Counter('my_meetings_requests');
const myMeetingDetailDuration = new Trend('my_meeting_detail_duration', true);

export const options = {
  scenarios: {
    n1_test: {
      executor: 'ramping-vus',
      startVUs: 10,
      stages: [
        { duration: '1m', target: 100 },
        { duration: '3m', target: 300 },
        { duration: '2m', target: 100 },
        { duration: '1m', target: 0 },
      ],
    },
  },
  thresholds: {
    my_meetings_duration: ['p(95)<500', 'p(99)<1000'],
    my_meeting_detail_duration: ['p(95)<800', 'p(99)<1500'],
    http_req_failed: ['rate<0.01'],
  },
};

export function setup() {
  const hasAuth = initAuth();
  if (!hasAuth) {
    console.error('JWT_TOKEN 또는 REFRESH_TOKEN 환경변수가 필요합니다.');
  }
  return { hasAuth };
}

export default function (data) {
  if (!data.hasAuth) {
    return;
  }

  // 1. 내 모임 목록 조회 (N+1 발생 지점)
  group('내 모임 목록 (N+1)', function () {
    const start = Date.now();

    // size=10으로 요청 시 21개 쿼리 예상
    const res = apiGet('/users/me/meetings?status=ACTIVE&size=10', {}, true);

    const duration = Date.now() - start;
    myMeetingsDuration.add(duration);
    myMeetingsRequests.add(1);

    check(res, {
      'My meetings - status 200': (r) => r.status === 200,
      'My meetings - under 500ms': (r) => r.timings.duration < 500,
      'My meetings - under 1s': (r) => r.timings.duration < 1000,
    });

    const myData = extractData(res);
    if (myData && myData.items && myData.items.length > 0) {
      console.log(`조회된 모임 수: ${myData.items.length} (예상 쿼리: ${1 + myData.items.length * 2}개)`);
    }
  });

  thinkTime(2, 4);

  // 2. 내 모임 상세 조회 (회차별 독후감 N+1)
  group('내 모임 상세 (회차별 N+1)', function () {
    // 먼저 목록에서 모임 ID 가져오기
    const listRes = apiGet('/users/me/meetings?status=ACTIVE&size=5', {}, true);
    const listData = extractData(listRes);

    if (listData && listData.items && listData.items.length > 0) {
      const meetingId = listData.items[0].meetingId;

      const start = Date.now();
      const detailRes = apiGet(`/users/me/meetings/${meetingId}`, {}, true);

      const duration = Date.now() - start;
      myMeetingDetailDuration.add(duration);

      check(detailRes, {
        'My meeting detail - status 200': (r) => r.status === 200,
        'My meeting detail - under 800ms': (r) => r.timings.duration < 800,
      });

      const detailData = extractData(detailRes);
      if (detailData && detailData.rounds) {
        console.log(`모임 회차 수: ${detailData.rounds.length} (예상 독후감 쿼리: ${detailData.rounds.length}개)`);
      }
    }
  });

  thinkTime(2, 4);
}
